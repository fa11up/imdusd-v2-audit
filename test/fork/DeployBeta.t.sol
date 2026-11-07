// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test, console2} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Deploy} from "../../script/Deploy.s.sol";
import {DeployBeta} from "../../script/DeployBeta.s.sol";
import {DeployTypes, MainnetConfig, BetaConfig} from "../../script/DeployConfig.sol";
import {Mainnet} from "./MainnetAddresses.sol";
import {ImdUSD} from "../../src/ImdUSD.sol";
import {ParametersBase} from "../../src/ParametersBase.sol";
import {Parameters} from "../../src/Parameters.sol";
import {Treasury, ICoverable} from "../../src/Treasury.sol";
import {Ledger} from "../../src/Ledger.sol";
import {LedgerBase} from "../../src/LedgerBase.sol";
import {Migrator} from "../../src/Migrator.sol";
import {Governed} from "../../src/Governed.sol";
import {Join} from "../../src/Join.sol";
import {PegHook} from "../../src/peg/PegHook.sol";
import {SwarmFeed} from "../../src/feeds/SwarmFeed.sol";
import {CompoundHook} from "../../src/dex/CompoundHook.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {PoolId} from "v4-core/src/types/PoolId.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {Adjust} from "../../src/interfaces/IPositions.sol";
import {_pid} from "../utils/Pid.sol";
import {Backstop} from "../../src/backstop/Backstop.sol";

interface IAggBeta {
    function latestRoundData() external view returns (uint80, int256, uint256, uint256, uint80);
}

/// @notice Fork rehearsal of the capped live beta: script/DeployBeta.s.sol's config through the real deploy script
/// on a mainnet fork, checked against the beta parameter set (hard-coded below as the independent source), then the Safe's
/// post-deploy batch and the migration opening on the deployed system.
/// Run: MAINNET_RPC_URL=<rpc> forge test --match-path test/fork/DeployBeta.t.sol
/// Value dump for the line-by-line review: add `--match-test test_printBetaValues -vv` and `grep '^BETA '`.
contract DeployBetaForkTest is Test {
    using SafeERC20 for IERC20;

    address deployer = makeAddr("deployer");
    address alice = makeAddr("alice");
    address safe = Mainnet.GOVERNANCE_SAFE;
    address constant USDC_WHALE = 0xBBBBBbbBBb9cC5e90e3b3Af64bdAF62C37EEFFCb; // Morpho Blue
    /// @dev A real imdUSD v1 holder: the v4 PoolManager holds the v1 peg pool's imdUSD (57,129 on 2026-10-21).
    address constant V1_HOLDER = Mainnet.UNIV4_POOL_MANAGER;

    DeployBeta script;
    Deploy.Deployed d;
    uint256 deployerNonce;

    // The beta parameter set, written out independently of BetaConfig.
    function _section5Line(bytes32 ilk) internal pure returns (uint256) {
        if (ilk == "SIMD") return 0; // D2: opens on day 7 with the keeper cap (target 50k, D1-gated)
        if (ilk == "ETH" || ilk == "WSTETH") return 50_000e18;
        if (ilk == "CBBTC" || ilk == "WBTC") return 25_000e18;
        if (ilk == "S-USDS" || ilk == "S-USDC-STEAKHOUSE") return 12_500e18; // pEG's 25k carved from these
        if (ilk == "USDC" || ilk == "USDT") return 25_000e18;
        revert("ilk not in section 5");
    }

    /// @dev Blue types redeem with divisor 16 in the beta (full config 4); stables 8 and sIMD 2 as in full.
    function _betaDivisor(bytes32 ilk, uint256 full) internal pure returns (uint256) {
        if (ilk == "ETH" || ilk == "WSTETH" || ilk == "CBBTC" || ilk == "WBTC") return 16;
        return full;
    }

    uint256 constant S5_TOTAL = 300_000e18;
    uint256 constant S5_FLASH_CAP = 100_000e18;
    uint256 constant S5_SAVINGS = 0.35e18;
    uint256 constant S5_BUFFER_TARGET = 5_000e6;
    uint256 constant S5_KEEPER_CAP_STEP = 50_000e18;

    function setUp() public virtual {
        vm.createSelectFork(vm.envOr("MAINNET_RPC_URL", string("https://ethereum-rpc.publicnode.com")));
        vm.deal(deployer, 10 ether);
        script = new DeployBeta();
        d = script.deployAs(script.config(), deployer);
        deployerNonce = vm.getNonce(deployer);
    }

    function _cfg() internal view returns (DeployTypes.Config memory) {
        return script.config();
    }

    // ------------------------------------------------------------ selection + config == the beta parameter set

    function test_betaScriptSelectsBetaConfig() public {
        assertEq(abi.encode(script.config()), abi.encode(BetaConfig.get()), "DeployBeta deploys BetaConfig");
        Deploy full = new Deploy();
        assertEq(abi.encode(full.config()), abi.encode(MainnetConfig.get()), "Deploy deploys the full config");
        assertFalse(MainnetConfig.get().migratorClosed, "full config keeps migration open");
        // The full config's genesis line is still max(150k, 2 x v1 supply); the beta's is 0.
        uint256 twice = 2 * IERC20(Mainnet.V1_IMDUSD).totalSupply();
        assertEq(full.migratorLineFor(MainnetConfig.get()), twice > 150_000e18 ? twice : 150_000e18);
        assertEq(script.migratorLineFor(BetaConfig.get()), 0);
    }

    /// @dev Beta = full config except the beta knobs: every feed, token and non-line risk value is the full one.
    function test_betaDiffersFromFullOnlyInSection5() public pure {
        DeployTypes.Config memory b = BetaConfig.get();
        DeployTypes.Config memory f = MainnetConfig.get();
        assertEq(b.governor, f.governor);
        assertEq(b.v1, f.v1);
        assertEq(b.poolManager, f.poolManager);
        assertEq(b.pegQuote, f.pegQuote);
        assertEq(b.savingsShare, f.savingsShare);
        assertEq(b.migratorLine, f.migratorLine, "floor kept for the day migration opens");
        // Every full-config node, in order, then the two seat leaves the beta appends.
        assertEq(b.feeds.length, f.feeds.length + 2, "feeds + 2 seat legs");
        for (uint256 i; i < f.feeds.length; ++i) assertEq(abi.encode(b.feeds[i]), abi.encode(f.feeds[i]), "feeds");
        assertEq(b.feeds[BetaConfig.F_SEAT_MEDIAN].kind, DeployTypes.SWARM_SEAT_MEDIAN);
        assertEq(b.feeds[BetaConfig.F_SEAT_SPOT].kind, DeployTypes.SWARM_SEAT_SPOT);
        assertEq(b.ilks.length, f.ilks.length);
        for (uint256 i; i < b.ilks.length; ++i) {
            DeployTypes.IlkSpec memory bi = b.ilks[i];
            DeployTypes.IlkSpec memory fi = f.ilks[i];
            assertEq(bi.risk.line, _section5Line(bi.ilk), "beta line");
            bi.risk.line = fi.risk.line;
            assertEq(bi.risk.redeemDivisor, _betaDivisor(bi.ilk, fi.risk.redeemDivisor), "beta redemption divisor");
            bi.risk.redeemDivisor = fi.risk.redeemDivisor;
            assertEq(abi.encode(bi), abi.encode(fi), "only the line and the blue divisor differ");
        }
        // The beta alone caps the chain (300k) and turns the sIMD grace off.
        assertTrue(b.chain.capped && !f.chain.capped, "beta capped, full uncapped");
        assertEq(b.chain.chainLine, S5_TOTAL);
        assertEq(f.chain.chainLine, 0);
        assertTrue(b.graceOff && !f.graceOff, "sIMD grace off in the beta only");
    }

    function test_configIsSection5() public pure {
        DeployTypes.Config memory b = BetaConfig.get();
        uint256 total;
        for (uint256 i; i < b.ilks.length; ++i) total += b.ilks[i].risk.line;
        // The PEG line counts in the chain cap, so it is inside the stated budget.
        assertTrue(b.pegPositions.enabled);
        assertEq(b.pegPositions.risk.line, BetaConfig.PEG_LINE);
        total += b.pegPositions.risk.line;
        assertEq(total + BetaConfig.SIMD_LINE_TARGET, S5_TOTAL, "total possible debt once sIMD opens, PEG included");
        assertEq(total + BetaConfig.SIMD_LINE_TARGET, BetaConfig.TOTAL_LINES);
        assertEq(b.flashCap, S5_FLASH_CAP);
        assertEq(b.savingsShare, S5_SAVINGS);
        assertTrue(b.migratorClosed);
        assertTrue(b.lpVault.enabled, "PegLPVault ON from day 1");
        assertEq(b.lpVault.band, MainnetConfig.get().lpVault.band, "as the full config");
        assertFalse(b.loopVault.enabled);
        assertTrue(b.seats.enabled, "seats in the beta");
        assertEq(b.seats.maxSeats, 25);
        assertEq(b.seats.perBorrower, 3);
        assertEq(b.seats.risk.mat, 2.5e18);
        assertEq(b.seats.risk.line, 40_000e18);
        assertEq(b.seats.median, BetaConfig.F_SEAT_MEDIAN);
        assertEq(b.seats.spot, BetaConfig.F_SEAT_SPOT);
        assertFalse(b.dex.enabled);
        assertTrue(b.poolManager != address(0) && b.pegQuote != address(0), "PegHook + FeeNotes in the beta");
    }

    /// @dev Divisor 16 on the four blue types (the Parameters bound), 8 on stables, 2 on sIMD.
    function test_betaRedemptionDivisors() public pure {
        DeployTypes.Config memory b = BetaConfig.get();
        for (uint256 i; i < b.ilks.length; ++i) {
            bytes32 k = b.ilks[i].ilk;
            uint256 want = (k == "ETH" || k == "WSTETH" || k == "CBBTC" || k == "WBTC") ? 16 : k == "SIMD" ? 2 : 8;
            assertEq(b.ilks[i].risk.redeemDivisor, want, "divisor");
        }
    }

    // ------------------------------------------------------------ deployed == BetaConfig == the beta parameter set

    function test_deployedMatchesBetaConfig() public view {
        DeployTypes.Config memory c = _cfg();
        assertEq(d.params.ilkCount(), c.ilks.length + 2, "9 types + SEAT + PEG");
        assertTrue(d.params.exists("PEG"));
        assertTrue(d.params.exists("SEAT"));
        uint256 total;
        for (uint256 i; i < c.ilks.length; ++i) {
            DeployTypes.IlkSpec memory s = c.ilks[i];
            assertEq(d.params.ilks(i), s.ilk, "order");
            ParametersBase.Risk memory r = d.params.storedRisk(s.ilk);
            assertEq(abi.encode(r), abi.encode(s.risk), "risk == BetaConfig");
            assertEq(r.line, _section5Line(s.ilk), "line == section 5");
            total += r.line;
            ParametersBase.Config memory k = d.params.config(s.ilk);
            assertEq(k.token, s.token, "token");
            assertEq(k.join, address(d.joins[i]), "join");
            assertEq(address(k.median), address(d.feeds[s.median]), "median");
            assertEq(address(k.spot), address(d.feeds[s.spot]), "spot");
            assertEq(k.redeemable, s.redeemable, "redeemable");
            assertFalse(k.auction);
        }
        assertEq(d.params.storedRisk("PEG").line, BetaConfig.PEG_LINE, "PEG line");
        total += d.params.storedRisk("PEG").line;
        assertEq(total + BetaConfig.SIMD_LINE_TARGET, S5_TOTAL, "deployed lines (PEG incl.) + the day-7 sIMD line");
        assertEq(d.params.depthIlk(), bytes32("SIMD"), "D1 rule on sIMD");
        assertEq(d.params.depthK(), 0.8e18);
        assertEq(d.params.depthCap(), 80_100e18, "posted cap on the measured depth");
        assertEq(d.usd.flashCap(), S5_FLASH_CAP, "flash cap");
        assertEq(d.params.migratorLine(), 0, "migration closed");
        assertEq(d.params.keeperCap(), 0, "keeper cap 0 at genesis");
        (address sv, uint256 share) = d.params.savingsSplit();
        assertEq(sv, address(d.savings));
        assertEq(share, S5_SAVINGS);
        assertEq(d.hook.buffer(), 0, "the buffer starts empty");
        assertEq(d.params.bufferTarget(), 0, "its target is set by the Safe, not the script");
        assertEq(d.usd.keeper(), address(d.hook));
        assertEq(d.notes.count(), 0, "no fee-note series");
        assertEq(d.params.notes(), address(d.notes));
        assertEq(d.treasury.notes(), address(d.notes));
        assertEq(d.usd.totalSupply(), 0);
        (bool capped, uint256 chainLine) = d.params.chainCap();
        assertTrue(capped, "chain capped at genesis");
        assertEq(chainLine, S5_TOTAL, "chain line 300k");
        assertEq(d.params.maxLull(), 0, "no liquidation grace");
        assertEq(d.pricer.quote("SIMD").lull, 0, "sIMD: no grace whatever the NHI");
    }

    /// @dev Σ debt + bad debt of every type stays within the 300k chain line. The type lines alone sum to
    /// 250k at genesis, so the Safe first lifts ETH's line to 400k (48h); then a borrow that would take the chain past 300k
    /// reverts while one that stays inside lands, whatever the type line says.
    function test_chainLineBindsAt300k() public {
        ParametersBase.Risk memory r = d.params.storedRisk("ETH");
        r.line = 400_000e18;
        vm.prank(safe);
        d.params.propose(abi.encode(uint8(1), bytes32("ETH"), r));
        vm.warp(vm.getBlockTimestamp() + 48 hours);
        d.params.applyPending();
        assertEq(d.params.storedRisk("ETH").line, 400_000e18);

        _freshEth();
        deal(Mainnet.WETH, alice, 1_000e18);
        vm.startPrank(alice);
        IERC20(Mainnet.WETH).forceApprove(address(d.ledger), 1_000e18);
        (uint256 p, uint256 n) = d.ledger.sorted().findInsertPosition("ETH", 0.05e18);
        d.ledger.open("ETH", 0, Adjust(1_000e18, 290_000e18, 0.05e18, p, n, false, type(uint256).max, address(0)));
        uint256 debt = d.ledger.debtOf(_pid("ETH", alice));
        assertGt(debt, 290_000e18, "upfront fee counted");
        vm.expectRevert(LedgerBase.ChainLineExceeded.selector);
        d.ledger.open("ETH", 0, Adjust(0, int256(300_000e18 - debt + 1e18), 0, 0, 0, false, type(uint256).max, address(0)));
        d.ledger.open("ETH", 0, Adjust(0, int256(300_000e18 - debt) * 99 / 100, 0, 0, 0, false, type(uint256).max, address(0)));
        vm.stopPrank();
        assertLe(d.ledger.debtOf(_pid("ETH", alice)), 300_000e18, "inside the chain line");
    }

    /// @dev Total possible debt = every ceiling + migrator line + keeper cap = 300k at genesis. Borrowing proves the
    /// line binds: the ETH ceiling fills to exactly 50k and not one wei more.
    function test_ethCeilingBindsAt50k() public {
        _freshEth();
        bytes32 ilk = "ETH";
        deal(Mainnet.WETH, alice, 1_000e18);
        vm.startPrank(alice);
        IERC20(Mainnet.WETH).forceApprove(address(d.ledger), 1_000e18);
        (uint256 p, uint256 n) = d.ledger.sorted().findInsertPosition(ilk, 0.05e18);
        // The line counts the upfront fee (7 days at 5%): the most that can be drawn is 50k / (1 + 0.000959).
        uint256 most = uint256(50_000e18) * 365 days / (365 days + 0.05e18 * 7 days / 1e18) / 1e18 * 1e18;
        vm.expectRevert(LedgerBase.CeilingExceeded.selector);
        d.ledger.open(ilk, 0, Adjust(1_000e18, int256(most + 1e18), 0.05e18, p, n, false, type(uint256).max, address(0)));
        d.ledger.open(ilk, 0, Adjust(1_000e18, int256(most), 0.05e18, p, n, false, type(uint256).max, address(0)));
        vm.stopPrank();
        assertLe(d.ledger.debtOf(_pid(ilk, alice)), 50_000e18);
        assertGt(d.ledger.debtOf(_pid(ilk, alice)), 49_999e18, "binds at 50k, fee included");
    }

    function _freshEth() internal {
        (uint80 id, int256 answer,,, uint80 ans) = IAggBeta(Mainnet.CL_ETH_USD).latestRoundData();
        vm.mockCall(
            Mainnet.CL_ETH_USD,
            abi.encodeWithSignature("latestRoundData()"),
            abi.encode(id, answer, block.timestamp, block.timestamp, ans)
        );
    }

    // ------------------------------------------------------------ authority: the Safe, and nothing for the deployer

    function test_everyAuthorityIsTheSafe() public {
        assertEq(d.params.governor(), safe, "params governor");
        assertEq(d.treasury.governor(), safe, "treasury governor");
        assertTrue(d.params.sealed_(), "sealed");
        assertEq(d.usd.ledger(), address(d.ledger));
        assertEq(d.usd.migrator(), address(d.migrator));
        assertEq(d.usd.bridgeSetter(), address(d.params));
        assertEq(d.usd.bridge(), address(0));
        assertEq(address(d.hook.params()), address(d.params));
        assertEq(d.hook.treasury(), address(d.treasury));

        ParametersBase.Config memory c0 = d.params.config("ETH");
        ParametersBase.Risk memory r0 = d.params.storedRisk("ETH");
        vm.startPrank(deployer);
        vm.expectRevert(ImdUSD.AlreadySet.selector);
        d.usd.wire(address(d.ledger), address(d.migrator), address(d.params));
        vm.expectRevert(ImdUSD.Unauthorized.selector);
        d.usd.mint(deployer, 1);
        vm.expectRevert(ParametersBase.Sealed.selector);
        d.params.addGenesisIlk("NEW", c0, r0);
        vm.expectRevert(ParametersBase.Sealed.selector);
        d.params.setGenesisMigratorLine(type(uint256).max);
        vm.expectRevert(ParametersBase.Sealed.selector);
        d.params.setGenesisKeeper(deployer);
        assertEq(d.params.SET_MIGRATOR_LINE(), 3);
        bytes memory openLine = abi.encode(uint8(3), uint256(1)); // SET_MIGRATOR_LINE
        vm.expectRevert(Governed.NotGovernor.selector);
        d.params.propose(openLine);
        vm.expectRevert(Governed.NotGovernor.selector);
        d.treasury.propose(abi.encode(address(d.usd), deployer, uint256(1)));
        vm.expectRevert(Treasury.AlreadyWired.selector);
        d.treasury.wire(ICoverable(address(d.ledger)));
        vm.expectRevert(LedgerBase.AlreadyWired.selector);
        d.ledger.wire(deployer, deployer);
        vm.expectRevert(PegHook.NotGovernor.selector);
        d.hook.pullBuffer(0);
        for (uint256 i; i < d.joins.length; ++i) {
            vm.expectRevert(Join.AlreadyWired.selector);
            d.joins[i].wire(deployer);
        }
        vm.stopPrank();
        assertEq(d.usd.balanceOf(deployer), 0);
    }

    // ------------------------------------------------------------ seats: deployed empty, priced once the legs land

    function test_seatsDeployedEmptyAndUnpriced() public view {
        DeployTypes.Config memory c = _cfg();
        assertEq(address(d.seatFeed.median()), address(d.feeds[c.seats.median]));
        assertEq(address(d.seatFeed.spot()), address(d.feeds[c.seats.spot]));
        assertEq(address(d.seatSpot.feed()), address(d.seatFeed));
        assertEq(address(d.seatJoin.ledger()), address(d.ledger));
        ParametersBase.Config memory pc = d.params.config("SEAT");
        assertTrue(pc.auction && !pc.redeemable, "auction type, never redeemed");
        assertEq(address(pc.median), address(d.seatFeed));
        assertEq(address(pc.spot), address(d.seatSpot));
        // Both legs are fresh leaves: empty, so the type reads 0 and is stale until the deployment relays them.
        (uint256 v,) = d.seatFeed.latestValue();
        assertEq(v, 0);
        assertTrue(d.seatFeed.isStale());
        (uint256 m,) = d.feeds[c.seats.median].latestValue();
        assertEq(m, 0, "median leaf empty at deploy");
        assertEq(d.seatFeed.liquidity(), 0, "no count yet");
        // The leaves pin the production questions (the frozen request payloads).
        assertEq(
            SwarmFeed(address(d.feeds[c.seats.median])).expectedQuestionHash(26223897, 26274136),
            0x9a2a1d854239023e28f96c68638808d83fc4b31c8323b1d059e2fcdb92033f85
        );
        assertEq(
            SwarmFeed(address(d.feeds[c.seats.spot])).expectedQuestionHash(26223897, 26274136),
            0xd4f124132f999070c20f5770cff09cbdad1bec6bcf7cf703375780d86ea9b72b
        );
    }

    // ------------------------------------------------------------ the modules that are OFF are not there

    function test_pegLPVaultDeployedAsInFull() public view {
        assertTrue(address(d.pegLP).code.length != 0, "PegLPVault deployed (F2)");
        assertEq(address(d.pegLP.hook()), address(d.hook));
        assertEq(d.pegLP.treasury(), address(d.treasury));
        assertEq(d.pegLP.tickUpper() - d.pegLP.tickLower(), 2 * _cfg().lpVault.band);
        assertEq(d.pegLP.totalSupply(), 0, "not seeded by the script");
    }

    function test_offModulesAreNotDeployed() public view {
        assertEq(address(d.loop), address(0), "LoopVault");
        assertEq(address(d.dexHook), address(0), "CompoundHook");
        assertEq(address(d.dexLens), address(0), "CompoundLens");
        assertEq(d.curveLib, address(0));
        assertEq(d.oracleLib, address(0));

        // Everything the deployer created (CREATE, nonce by nonce) is a known in-beta contract: no vault, lens or
        // seat contract hides at a later nonce. (Non-hollow: the core alone is ~30 creates.)
        assertGt(deployerNonce - _firstNonce(), 30, "deployer created the system");
        uint256 found;
        for (uint256 n = _firstNonce(); n < deployerNonce + 8; ++n) {
            address a = vm.computeCreateAddress(deployer, n);
            if (a.code.length == 0) continue;
            assertTrue(_isBetaContract(a), "unexpected contract at a deployer nonce");
            ++found;
        }
        assertEq(
            found,
            10 + d.joins.length + _createdFeeds() + 3 + 1 + 2 + d.samplers.length + 4 + 5,
            "every create accounted for (+ 3 seat contracts + PegLPVault + PositionNFT + ImdDepth + samplers + PricerOracle, 2 sleeves, Allocator + 5 peg)"
        );

        // The Compound DEX hook's would-be address (same init code and mining rule as the script) is empty.
        DeployTypes.Config memory full = MainnetConfig.get();
        (uint160 sp,,,) =
            StateLibrary.getSlot0(IPoolManager(full.poolManager), PoolId.wrap(full.dex.marketPoolId));
        bytes memory init = abi.encodePacked(
            type(CompoundHook).creationCode,
            abi.encode(
                IPoolManager(full.poolManager),
                IERC4626(full.dex.vaultA),
                IERC4626(full.dex.vaultB),
                address(d.treasury),
                sp
            )
        );
        uint160 flags = Hooks.BEFORE_INITIALIZE_FLAG | Hooks.BEFORE_ADD_LIQUIDITY_FLAG | Hooks.BEFORE_SWAP_FLAG
            | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG;
        bytes32 h = keccak256(init);
        for (uint256 salt;; ++salt) {
            address a = vm.computeCreate2Address(bytes32(salt), h, CREATE2_DEPLOYER);
            if (uint160(a) & Hooks.ALL_HOOK_MASK != flags) continue;
            assertEq(a.code.length, 0, "dex hook would-be address has code");
            break;
        }
    }

    /// @dev The deployer's first nonce of this deployment (a fresh test address: 0; a launch record: its startNonce).
    function _firstNonce() internal view virtual returns (uint256) {
        return 0;
    }

    function _createdFeeds() internal view returns (uint256 n) {
        DeployTypes.Config memory c = _cfg();
        for (uint256 i; i < c.feeds.length; ++i) if (c.feeds[i].kind != DeployTypes.EXISTING) ++n;
    }

    address constant CREATE2_DEPLOYER = 0x4e59b44847b379578588920cA78FbF26c0B4956C;

    function _isBetaContract(address a) internal view returns (bool) {
        address[10] memory core = [
            address(d.usd),
            address(d.params),
            address(d.pricer),
            address(d.treasury),
            address(d.ledger),
            address(d.redeemer),
            address(d.liquidator),
            address(d.migrator),
            address(d.savings),
            address(d.notes)
        ];
        for (uint256 i; i < core.length; ++i) if (a == core[i]) return true;
        for (uint256 i; i < d.joins.length; ++i) if (a == address(d.joins[i])) return true;
        for (uint256 i; i < d.feeds.length; ++i) if (a == address(d.feeds[i])) return true;
        for (uint256 i; i < d.samplers.length; ++i) if (a == address(d.samplers[i])) return true;
        return a == address(d.seatJoin) || a == address(d.seatFeed) || a == address(d.seatSpot) || a == address(d.pegLP)
            || a == address(d.ledger.nft()) || a == address(d.imdDepth) || a == address(d.backstopOracle) || a == address(d.blue)
            || a == address(d.edge) || a == address(d.allocator) || a == address(d.pegFeed) || a == address(d.pegJoin)
            || a == address(d.pegZap) || a == address(d.pegCollateral) || a == address(d.params.config("PEG").spot);
    }

    // ------------------------------------------------------------ the standing bid, as deployed

    function test_backstopDeployedAndWired() public view {
        assertEq(d.params.blueBackstop(), address(d.blue), "Parameters -> blue");
        assertEq(d.params.edgeBackstop(), address(d.edge), "Parameters -> edge");
        assertEq(d.params.edgePremium(), 0.2e18, "edge premium 20%");
        assertTrue(d.backstopOracle.sealed_() && d.blue.isSealed() && d.edge.isSealed(), "sealed");
        assertEq(d.backstopOracle.params(), address(d.params), "only Parameters maps after the seal");
        Backstop[2] memory sl = [d.blue, d.edge];
        for (uint256 k; k < 2; ++k) {
            assertEq(sl[k].liquidator(), address(d.liquidator), "bids come from the real Liquidator");
            assertEq(sl[k].params(), address(d.params), "lists through Parameters");
            assertEq(sl[k].seller(), address(d.allocator), "sells through the Allocator");
            assertEq(address(sl[k].ledger()), address(d.ledger), "the real Ledger");
        }
        DeployTypes.BackstopSpec memory b = _cfg().backstop;
        for (uint256 i; i < b.ilks.length; ++i) {
            address token = d.params.config(b.ilks[i].ilk).token;
            assertEq(d.backstopOracle.ilkOf(token), b.ilks[i].ilk, "oracle maps the token");
            (address listed,,, bool on) = (b.ilks[i].edge ? d.edge : d.blue).ilks(b.ilks[i].ilk);
            assertTrue(listed == token && on, "listed in its sleeve");
            assertEq(d.params.edgeIlk(b.ilks[i].ilk), b.ilks[i].edge, "edge flag");
        }
        assertTrue(d.params.edgeIlk("SIMD"), "sIMD is the edge type");
        assertFalse(d.params.edgeIlk("ETH"), "ETH is blue");
        assertEq(d.allocator.governor(), safe, "Allocator governor = the Safe");
        assertEq(d.allocator.treasury(), address(d.treasury), "Allocator pays back to the Treasury");
    }

    /// @dev A covered ETH loan, on the deployed system, liquidated after a fall: the blue sleeve fills the standing bid in
    /// the same transaction (it receives the WETH and spends imdUSD), and the kicker earns only the marker's chip.
    function test_standingBidFillsOnTheDeployedSystem() public {
        _freshEth();
        address carol = makeAddr("carol");
        address kicker = makeAddr("kicker");
        bytes32 ilk = "ETH";
        (uint80 id_, int256 ans,,, uint80 ar) = IAggBeta(Mainnet.CL_ETH_USD).latestRoundData();
        uint256 px = uint256(ans) * 1e10; // USD per ETH, 1e18
        // carol funds the blue sleeve with borrowed imdUSD
        deal(Mainnet.WETH, carol, 100e18);
        vm.startPrank(carol);
        IERC20(Mainnet.WETH).forceApprove(address(d.ledger), 100e18);
        d.ledger.open(ilk, 0, Adjust(100e18, int256(20_000e18), 0.05e18, 0, 0, false, type(uint256).max, address(0)));
        d.usd.approve(address(d.blue), type(uint256).max);
        d.blue.deposit(19_000e18, carol);
        vm.stopPrank();
        // bob borrows close to the line
        deal(Mainnet.WETH, alice, 10e18);
        vm.startPrank(alice);
        IERC20(Mainnet.WETH).forceApprove(address(d.ledger), 10e18);
        uint256 debt = 10 * px * 1e18 / 1.5e18; // 150% at today's price (mat 140%)
        d.ledger.open(ilk, 0, Adjust(10e18, int256(debt), 0.05e18, 0, 0, false, type(uint256).max, address(0)));
        vm.stopPrank();
        uint256 id = _pid(ilk, alice);
        // carol's deposit matures once its UTC day and one more full day have passed (day buckets), then ETH falls 10%
        // (150% -> 135%, under the 140% line)
        vm.warp(vm.getBlockTimestamp() + 2 days + 1 hours);
        vm.mockCall(
            Mainnet.CL_ETH_USD,
            abi.encodeWithSignature("latestRoundData()"),
            abi.encode(id_, ans * 90 / 100, block.timestamp, block.timestamp, ar)
        );
        (bool ok,) = d.ledger.healthy(id);
        assertFalse(ok, "under water after the fall");
        uint256 usd0 = d.usd.balanceOf(address(d.blue));
        uint256 weth0 = IERC20(Mainnet.WETH).balanceOf(address(d.blue));
        // bidRoom() reads 0 here: matured deposits are converted by openBid inside the liquidation, not before.
        vm.prank(kicker);
        d.liquidator.liquidate(id);
        assertGt(IERC20(Mainnet.WETH).balanceOf(address(d.blue)), weth0, "the sleeve received the collateral");
        assertLt(d.usd.balanceOf(address(d.blue)), usd0, "the sleeve paid imdUSD for it");
        assertEq(d.usd.balanceOf(kicker), 0, "no imdUSD needed or earned by the kicker");
    }

    // ------------------------------------------------------------ migration: closed at genesis, opens via the timelock

    function test_migrationClosedAtGenesisOpensThroughTheTimelock() public {
        uint256 amount = 1_000e18;
        IERC20 v1 = IERC20(Mainnet.V1_IMDUSD);
        assertGe(v1.balanceOf(V1_HOLDER), amount, "real v1 holder");
        vm.prank(V1_HOLDER);
        v1.approve(address(d.migrator), type(uint256).max);

        vm.prank(V1_HOLDER);
        vm.expectRevert(Migrator.OverLine.selector);
        d.migrator.toV2(1);

        // The Safe proposes max(150k, 2 x v1 supply on the day); anyone applies 48h later.
        uint256 twice = 2 * v1.totalSupply();
        uint256 line = twice > 150_000e18 ? twice : 150_000e18;
        bytes memory open = abi.encode(d.params.SET_MIGRATOR_LINE(), line);
        vm.prank(safe);
        d.params.propose(open);
        vm.warp(vm.getBlockTimestamp() + 48 hours - 1);
        vm.expectRevert(abi.encodeWithSelector(Governed.TooEarly.selector, vm.getBlockTimestamp() + 1));
        d.params.applyPending();
        vm.prank(V1_HOLDER);
        vm.expectRevert(Migrator.OverLine.selector);
        d.migrator.toV2(amount);
        vm.warp(vm.getBlockTimestamp() + 1);
        d.params.applyPending();
        assertEq(d.params.migratorLine(), line);

        uint256 v1Before = v1.balanceOf(V1_HOLDER);
        vm.prank(V1_HOLDER);
        d.migrator.toV2(amount);
        assertEq(d.usd.balanceOf(V1_HOLDER), amount, "v2 minted 1:1");
        assertEq(v1.balanceOf(address(d.migrator)), amount, "v1 held");
        assertEq(d.migrator.outstanding(), amount);
        vm.prank(V1_HOLDER);
        d.migrator.toV1(amount);
        assertEq(v1.balanceOf(V1_HOLDER), v1Before, "and back");
        assertEq(d.usd.totalSupply(), 0);
    }

    // ------------------------------------------------------------ the Safe's post-deploy batch

    /// @dev Day 0: buffer target 0 -> 5,000 USDC (48h; moves no money). Day 7: keeper cap 0 -> 50k
    /// (one week of TWAP history). Day 14: first ceiling step, ETH 50k -> 100k. Parameters has ONE pending slot, so
    /// the two timelocked acts are sequential, never stacked.
    function test_safePostDeployBatch() public {
        // 1. Buffer target (no USDC needed: the keeper fills it from its own profit).
        bytes memory target = abi.encode(d.params.SET_BUFFER_TARGET(), S5_BUFFER_TARGET);
        vm.prank(safe);
        d.params.propose(target);
        vm.warp(vm.getBlockTimestamp() + 48 hours);
        d.params.applyPending();
        assertEq(d.params.bufferTarget(), S5_BUFFER_TARGET, "buffer target set");
        assertEq(IERC20(Mainnet.USDC).balanceOf(address(d.hook)), 0, "and no money moved");

        // 2. Day 7: ONE proposal posts the depth, opens the sIMD line and raises the keeper cap 0 -> 50k.
        // At the 80.1k posted 7-day low, D1 (k 0.8, Robinhood's 3k IMD line counted: E2) refuses 50k and admits 33,733.
        vm.warp(vm.getBlockTimestamp() + 7 days);
        // By day 7 the keeper has sampled the exit pools hourly and poked ImdDepth daily; a fork cannot age
        // Chainlink with the warp, so the week's measured low is stood in for (test/unit/DepthMeasured.t.sol covers the
        // measurement itself, test/fork/DepthRule.fork.t.sol reads the live pools).
        vm.mockCall(address(d.imdDepth), abi.encodeWithSignature("depth()"), abi.encode(uint256(80_100e18)));
        ParametersBase.Risk memory sr = d.params.storedRisk("SIMD");
        bytes[] memory items = new bytes[](3);
        items[0] = abi.encode(d.params.SET_DEPTH(), uint256(80_100e18));
        sr.line = 50_000e18;
        items[1] = abi.encode(d.params.SET_RISK(), bytes32("SIMD"), sr);
        items[2] = abi.encode(d.params.SET_KEEPER_CAP(), S5_KEEPER_CAP_STEP);
        bytes memory day7 = abi.encode(d.params.BATCH(), items);
        vm.prank(safe);
        d.params.propose(day7);
        vm.warp(vm.getBlockTimestamp() + 48 hours);
        vm.expectRevert();
        d.params.applyPending();
        vm.prank(safe);
        d.params.cancel();
        sr.line = 33_733e18;
        assertEq(sr.line, MainnetConfig.simdLineFor(BetaConfig.SIMD_LINE_TARGET, 80_100e18), "same as the config's math");
        items[1] = abi.encode(d.params.SET_RISK(), bytes32("SIMD"), sr);
        bytes memory cap = abi.encode(d.params.BATCH(), items);
        vm.prank(safe);
        d.params.propose(cap);
        ParametersBase.Risk memory r = d.params.storedRisk("ETH");
        uint128 oldLine = r.line;
        r.line = 2 * oldLine;
        bytes memory raise = abi.encode(d.params.SET_RISK(), bytes32("ETH"), r);
        vm.prank(safe);
        vm.expectRevert(Governed.ProposalPending.selector);
        d.params.propose(raise);
        vm.warp(vm.getBlockTimestamp() + 48 hours);
        d.params.applyPending();
        assertEq(d.params.keeperCap(), S5_KEEPER_CAP_STEP, "keeper cap 50k");
        assertEq(d.params.storedRisk("SIMD").line, 33_733e18, "sIMD line opened with it");
        (bool holds,,) = d.params.depthRule();
        assertTrue(holds);

        // 3. ETH ceiling x2 after two weeks of no incident.
        vm.warp(vm.getBlockTimestamp() + 5 days);
        vm.prank(safe);
        d.params.propose(raise);
        vm.warp(vm.getBlockTimestamp() + 48 hours);
        d.params.applyPending();
        ParametersBase.Risk memory after_ = d.params.storedRisk("ETH");
        assertEq(after_.line, 100_000e18, "ETH line 100k");
        after_.line = oldLine;
        assertEq(abi.encode(after_), abi.encode(_cfg().ilks[0].risk), "nothing else moved");

        // The raised line binds at 100k.
        _freshEth();
        deal(Mainnet.WETH, alice, 1_000e18);
        vm.startPrank(alice);
        IERC20(Mainnet.WETH).forceApprove(address(d.ledger), 1_000e18);
        (uint256 p, uint256 n) = d.ledger.sorted().findInsertPosition("ETH", 0.05e18);
        uint256 most = uint256(100_000e18) * 365 days / (365 days + 0.05e18 * 7 days / 1e18) / 1e18 * 1e18; // fee incl.
        vm.expectRevert(LedgerBase.CeilingExceeded.selector);
        d.ledger.open("ETH", 0, Adjust(1_000e18, int256(most + 1e18), 0.05e18, p, n, false, type(uint256).max, address(0)));
        d.ledger.open("ETH", 0, Adjust(1_000e18, int256(most), 0.05e18, p, n, false, type(uint256).max, address(0)));
        vm.stopPrank();
        assertLe(d.ledger.debtOf(_pid("ETH", alice)), 100_000e18);
        assertGt(d.ledger.debtOf(_pid("ETH", alice)), 99_999e18);
    }

    // ------------------------------------------------------------ dump for the human line-by-line review

    /// @dev Every value READ FROM THE DEPLOYED SYSTEM, one per line: `BETA <key> <raw value>` (1e18 / 1e6 units as
    /// stored). `forge test --match-path test/fork/DeployBeta.t.sol --match-test test_printBetaValues -vv | grep '^BETA '`.
    function test_printBetaValues() public view {
        _p("flashCap", d.usd.flashCap());
        _p("migratorLine", d.params.migratorLine());
        _p("keeperCap", d.params.keeperCap());
        _p("savingsShare", d.params.savingsShare());
        _p("bufferTarget", d.params.bufferTarget());
        _p("buffer", d.hook.buffer());
        _p("noteSeries", d.notes.count());
        _p("ilkCount", d.params.ilkCount());
        _a("governor.params", d.params.governor());
        _a("governor.treasury", d.treasury.governor());
        _a("keeperMinter", d.usd.keeper());
        _a("module.pegLPVault", address(d.pegLP));
        _a("module.loopVault", address(d.loop));
        _a("module.seatJoin", address(d.seatJoin));
        _a("module.dexHook", address(d.dexHook));
        uint256 total;
        for (uint256 i; i < d.params.ilkCount(); ++i) {
            bytes32 ilk = d.params.ilks(i);
            string memory k = string.concat("ilk.", _str(ilk), ".");
            ParametersBase.Risk memory r = d.params.storedRisk(ilk);
            ParametersBase.Config memory c = d.params.config(ilk);
            total += r.line;
            _a(string.concat(k, "token"), c.token);
            _p(string.concat(k, "line"), r.line);
            _p(string.concat(k, "mat"), r.mat);
            _p(string.concat(k, "chop"), r.chop);
            _p(string.concat(k, "cut"), r.cut);
            _p(string.concat(k, "chip"), r.chip);
            _p(string.concat(k, "rateFloor"), r.rateFloor);
            _p(string.concat(k, "yieldFee"), r.yieldFee);
            _p(string.concat(k, "skew"), r.skew);
            _p(string.concat(k, "pegFloor"), r.pegFloor);
            _p(string.concat(k, "dust"), r.dust);
            _p(string.concat(k, "redeemFloor"), r.redeemFloor);
            _p(string.concat(k, "redeemDivisor"), r.redeemDivisor);
            _p(string.concat(k, "redeemCap"), r.redeemCap);
            _p(string.concat(k, "redeemable"), c.redeemable ? 1 : 0);
        }
        _p("totalLines", total);
    }

    function _p(string memory key, uint256 v) internal pure {
        console2.log(string.concat("BETA ", key, " ", vm.toString(v)));
    }

    function _a(string memory key, address v) internal pure {
        console2.log(string.concat("BETA ", key, " ", vm.toString(v)));
    }

    function _str(bytes32 b) internal pure returns (string memory) {
        uint256 n;
        while (n < 32 && b[n] != 0) ++n;
        bytes memory s = new bytes(n);
        for (uint256 i; i < n; ++i) s[i] = b[i];
        return string(s);
    }
}
