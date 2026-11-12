// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import "forge-std/Test.sol";
import {DeployTypes, MainnetConfig, BetaConfig} from "script/DeployConfig.sol";
import {DeployBase} from "script/deploy/DeployBase.sol";
import {StageTypes} from "script/deploy/StageTypes.sol";
import {Parameters} from "src/Parameters.sol";
import {ParametersBase} from "src/ParametersBase.sol";
import {Ledger} from "src/Ledger.sol";
import {IFeed} from "src/interfaces/IFeed.sol";

contract W1ResumeBlank {
    function ping() external pure returns (bool) {
        return true;
    }
}

/// Stage 3 exactly as the launch runs it: the stage function on a deployment record `d`.
contract W1Stage3 is StageTypes {
    function stage3(DeployTypes.Config memory cfg, Deployed memory d) external returns (Deployed memory) {
        _stageTypes(cfg, d, address(this));
        return d;
    }
}

/// Audit wave 1 (fa11up/imdusd-v2-audit at 2875ffb, panel 7; the judge's proof, adapted): a stage-3 resume refuses
/// (Mismatch) a type registered with other feeds or other risk than the config it is run with. It compared the join only.
contract AuditW1ResumeTypesTest is Test {
    W1Stage3 internal h;
    Parameters internal params;
    address internal ledger;
    address internal token;

    function setUp() public {
        h = new W1Stage3();
        params = new Parameters(address(0x5AFE), address(h)); // the stage contract is the wirer, as the deployer EOA is
        ledger = address(new W1ResumeBlank());
        token = address(new W1ResumeBlank());
        address usd = address(new W1ResumeBlank());
        vm.prank(address(h));
        params.wire(ledger, usd);
    }

    function _cfg(ParametersBase.Risk memory risk) internal view returns (DeployTypes.Config memory cfg) {
        cfg.migratorClosed = true;
        cfg.ilks = new DeployTypes.IlkSpec[](1);
        cfg.ilks[0] = DeployTypes.IlkSpec(
            "ETH", token, 0, 1, DeployTypes.NONE, DeployTypes.NONE, address(0), DeployTypes.NONE, true, risk
        );
    }

    function _record() internal returns (DeployBase.Deployed memory d) {
        d.params = params;
        d.ledger = Ledger(payable(ledger));
        d.feeds = _nodes();
    }

    function _nodes() internal returns (IFeed[] memory f) {
        f = new IFeed[](2);
        f[0] = IFeed(address(new W1ResumeBlank()));
        f[1] = IFeed(address(new W1ResumeBlank()));
    }

    /// Stage 3 stopped after ETH was registered from the full config (line 2,000,000), resumed with BetaConfig (50,000).
    function test_resumeWithOtherRiskIsRefused() public {
        ParametersBase.Risk memory full = MainnetConfig.get().ilks[0].risk;
        ParametersBase.Risk memory beta = BetaConfig.get().ilks[0].risk;
        assertEq(full.line, 2_000_000e18, "full ETH line");
        assertEq(beta.line, 50_000e18, "beta ETH line");

        DeployBase.Deployed memory d = h.stage3(_cfg(full), _record());
        vm.expectRevert(abi.encodeWithSelector(DeployBase.Mismatch.selector, "type registered with other risk"));
        h.stage3(_cfg(beta), d);
    }

    /// Stage 2 was re-run and deployed new feed nodes (the record now names them); stage 3 resumes on that record.
    function test_resumeWithRedeployedFeedsIsRefused() public {
        ParametersBase.Risk memory beta = BetaConfig.get().ilks[0].risk;
        DeployBase.Deployed memory d = h.stage3(_cfg(beta), _record());
        d.feeds = _nodes();
        vm.expectRevert(abi.encodeWithSelector(DeployBase.Mismatch.selector, "type registered with another config"));
        h.stage3(_cfg(beta), d);
    }

    /// The same config resumed is kept as it is (a resume that changes nothing still passes).
    function test_resumeWithTheSameConfigPasses() public {
        ParametersBase.Risk memory beta = BetaConfig.get().ilks[0].risk;
        DeployBase.Deployed memory d = h.stage3(_cfg(beta), _record());
        d = h.stage3(_cfg(beta), d);
        assertEq(params.storedRisk("ETH").line, beta.line);
    }
}