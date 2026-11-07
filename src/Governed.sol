// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/// @notice One proposal at a time, held public for `TIMELOCK`, then applied by anyone.
/// @dev v1's `Governed` with one change: the governor is an immutable constructor argument (the
/// governance Safe) instead of a source constant, so one codebase can deploy on several chains with a
/// different Safe on each. The delay rationale is unchanged: every value here is one a borrower priced
/// their position against, so nothing may change inside the window except a cancellation.
/// EXPIRY: a proposal left unapplied for `PROPOSAL_EXPIRY` past its ETA can no longer be
/// applied (`Expired`): a forgotten change must not land months later, when the figures it was validated against are
/// gone. `cancel` still clears it, and a fresh proposal restarts the 48h.
abstract contract Governed {
    uint256 public constant TIMELOCK = 48 hours;
    uint256 public constant PROPOSAL_EXPIRY = 14 days;

    /// @notice Who may propose and cancel.
    address public immutable governor;

    bytes public pending;
    uint256 public pendingEta;

    error NotGovernor();
    error NothingPending();
    error ProposalPending();
    error TooEarly(uint256 eta);
    error Expired(uint256 eta);
    error ZeroAddress();

    event Proposed(bytes payload, uint256 eta);
    event Cancelled(bytes payload);
    event Applied(bytes payload);

    constructor(address governor_) {
        if (governor_ == address(0)) revert ZeroAddress();
        governor = governor_;
    }

    modifier onlyGovernor() {
        if (msg.sender != governor) revert NotGovernor();
        _;
    }

    /// @notice Queue a change. Validated now and again at application.
    function propose(bytes calldata payload) external onlyGovernor {
        if (pendingEta != 0) revert ProposalPending();
        _validate(payload);
        pending = payload;
        pendingEta = block.timestamp + TIMELOCK;
        emit Proposed(payload, block.timestamp + TIMELOCK);
    }

    /// @notice Withdraw the pending change: the only action with no delay.
    function cancel() external onlyGovernor {
        if (pendingEta == 0) revert NothingPending();
        bytes memory payload = pending;
        delete pending;
        pendingEta = 0;
        emit Cancelled(payload);
    }

    /// @notice Apply the pending change once its delay has run. Callable by anyone.
    function applyPending() external {
        uint256 eta = pendingEta;
        if (eta == 0) revert NothingPending();
        if (block.timestamp < eta) revert TooEarly(eta);
        if (block.timestamp > eta + PROPOSAL_EXPIRY) revert Expired(eta);
        bytes memory payload = pending;
        delete pending;
        pendingEta = 0;
        _validate(payload);
        _apply(payload);
        emit Applied(payload);
    }

    function _validate(bytes memory payload) internal view virtual;

    function _apply(bytes memory payload) internal virtual;
}
