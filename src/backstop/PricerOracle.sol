// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {ParametersBase} from "../ParametersBase.sol";
import {Pricer} from "../Pricer.sol";
import {IBackstopOracle} from "./IBackstop.sol";

/// @notice A Backstop sleeve's prices: imdUSD per 1e18 raw units of a collateral token, read from the Pricer quote
/// of the type that pays out that token (low = the quote's `low`, high = its `high`, ok = `priced`). One type per token, set
/// by the deployer for every genesis token a sleeve covers, then sealed. After the seal only Parameters may map a NEW token
/// (its timelocked ADD_SLEEVE_ILK, for a type listed after launch). Nothing can ever repoint a token.
contract PricerOracle is IBackstopOracle {
    Pricer public immutable pricer;
    address public immutable deployer;
    /// @notice Parameters: the only mapper after the seal (new tokens only).
    address public immutable params;
    bool public sealed_;
    mapping(address token => bytes32) public ilkOf;

    error Unauthorized();
    error Sealed();
    error Exists();

    constructor(Pricer pricer_, address params_) {
        pricer = pricer_;
        params = params_;
        deployer = msg.sender;
    }

    function setIlk(address token, bytes32 ilk) external {
        if (sealed_ ? msg.sender != params : msg.sender != deployer) revert Unauthorized();
        if (ilkOf[token] != bytes32(0) || ilk == bytes32(0)) revert Exists();
        ilkOf[token] = ilk;
    }

    function seal() external {
        if (msg.sender != deployer) revert Unauthorized();
        sealed_ = true;
    }

    /// @dev A token with no type, or a quote that reverts, reads as unpriced (ok = false): the sleeve then refuses to value it.
    function priceOf(address token) external view returns (uint256 low, uint256 high, bool ok) {
        bytes32 ilk = ilkOf[token];
        if (ilk == bytes32(0)) return (0, 0, false);
        try pricer.quote(ilk) returns (Pricer.Quote memory q) {
            return (q.low, q.high, q.priced && q.low != 0);
        } catch {
            return (0, 0, false);
        }
    }

    /// @dev The legs `Pricer.quote` needs for `priced`: the median and any NHI. A leg that reverts reads as never updated.
    function pricedAt(address token) external view returns (uint256 at) {
        bytes32 ilk = ilkOf[token];
        if (ilk == bytes32(0)) return 0;
        ParametersBase.Config memory c = pricer.params().config(ilk);
        try c.median.latestValue() returns (uint256, uint64 t) {
            at = t;
        } catch {
            return 0;
        }
        if (address(c.nhi) == address(0)) return at;
        try c.nhi.latestValue() returns (uint256, uint64 t) {
            if (t < at) at = t;
        } catch {
            return 0;
        }
    }
}
