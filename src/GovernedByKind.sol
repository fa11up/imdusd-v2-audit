// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/// @notice `Governed`, with one pending proposal PER KIND instead of one overall.
/// @dev Same delay (48h), same expiry (14 days past the ETA), same errors and events as `Governed`, so tooling and tests
/// read the same selectors. A payload's kind is its first word. What changes:
///  - Each kind has its own slot: an urgent SET_RISK no longer waits behind a pending SET_DEPTH, or the reverse.
///  - A proposal also LOCKS the kinds it would change (`_kindsOf`: a plain proposal locks its own kind, a batch locks
///    BATCH and every item's kind). Proposing is refused while any of those kinds is locked by another pending proposal,
///    so no field can be pending twice (a lone SET_RISK and a batch carrying one cannot race each other). Kinds are still
///    re-validated at application, against the state then in force, so independent slots applying in any order only
///    ever apply changes that are valid at that moment.
///  - `applyPending(kind)` / `cancel(kind)` act on one slot. The no-argument `applyPending()` / `cancel()` and the
///    `pending()` / `pendingEta()` views keep `Governed`'s meaning while at most one slot is pending (scripts and the
///    Safe's tooling); with several pending the no-argument actions revert `SeveralPending` and the views name the
///    lowest pending kind's slot.
///  - An expired proposal still holds its slot (and its locks) until cancelled, as in `Governed`.
abstract contract GovernedByKind {
    uint256 public constant TIMELOCK = 48 hours;
    uint256 public constant PROPOSAL_EXPIRY = 14 days;

    /// @notice Who may propose and cancel.
    address public immutable governor;

    struct Slot {
        bytes payload;
        uint256 eta;
        uint256 locks; // bit k set = kind k is locked by this proposal
    }

    mapping(uint8 kind => Slot) internal _slots;
    /// @notice Bit k set = kind k is locked by some pending proposal.
    uint256 public locked;
    /// @notice Bit k set = a proposal of kind k is pending (its own slot is occupied).
    uint256 public pendingKinds;

    error NotGovernor();
    error NothingPending();
    error ProposalPending();
    error SeveralPending();
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

    /// @notice Queue a change in its kind's slot. Validated now and again at application.
    function propose(bytes calldata payload) external onlyGovernor {
        uint8 kind = abi.decode(payload, (uint8));
        uint256 locks = _kindsOf(payload);
        if (locks & locked != 0) revert ProposalPending();
        _validate(payload);
        uint256 eta = block.timestamp + TIMELOCK;
        _slots[kind] = Slot(payload, eta, locks);
        locked |= locks;
        pendingKinds |= 1 << kind;
        emit Proposed(payload, eta);
    }

    /// @notice Withdraw a kind's pending change: the only action with no delay.
    function cancel(uint8 kind) public onlyGovernor {
        Slot memory s = _take(kind);
        emit Cancelled(s.payload);
    }

    /// @notice Apply a kind's pending change once its delay has run. Callable by anyone.
    function applyPending(uint8 kind) public {
        uint256 eta = _slots[kind].eta;
        if (eta == 0) revert NothingPending();
        if (block.timestamp < eta) revert TooEarly(eta);
        if (block.timestamp > eta + PROPOSAL_EXPIRY) revert Expired(eta);
        bytes memory payload = _take(kind).payload;
        _validate(payload);
        _apply(payload);
        emit Applied(payload);
    }

    /// @notice `cancel(kind)` for the only pending proposal (reverts while several are pending).
    function cancel() external onlyGovernor {
        cancel(_onlyKind()); // the caller is checked first: a stranger learns nothing about what is pending
    }

    /// @notice `applyPending(kind)` for the only pending proposal (reverts while several are pending).
    function applyPending() external {
        applyPending(_onlyKind());
    }

    /// @notice A kind's pending payload and ETA (0 = none).
    function pendingOf(uint8 kind) external view returns (bytes memory payload, uint256 eta) {
        Slot storage s = _slots[kind];
        return (s.payload, s.eta);
    }

    /// @notice The pending payload when one proposal is pending; the lowest kind's when several; empty when none.
    function pending() external view returns (bytes memory) {
        return pendingKinds == 0 ? bytes("") : _slots[_lowestKind()].payload;
    }

    /// @notice The pending ETA when one proposal is pending; the lowest kind's when several; 0 when none.
    function pendingEta() external view returns (uint256) {
        return pendingKinds == 0 ? 0 : _slots[_lowestKind()].eta;
    }

    function _take(uint8 kind) internal returns (Slot memory s) {
        s = _slots[kind];
        if (s.eta == 0) revert NothingPending();
        delete _slots[kind];
        locked &= ~s.locks;
        pendingKinds &= ~(uint256(1) << kind);
    }

    function _onlyKind() private view returns (uint8) {
        uint256 p = pendingKinds;
        if (p == 0) revert NothingPending();
        if (p & (p - 1) != 0) revert SeveralPending();
        return _lowestKind();
    }

    function _lowestKind() private view returns (uint8 k) {
        uint256 p = pendingKinds;
        while (p & 1 == 0) {
            p >>= 1;
            ++k;
        }
    }

    /// @dev The kinds a payload would change, as a bit set. Default: its own kind. A batch kind overrides this.
    function _kindsOf(bytes memory payload) internal view virtual returns (uint256) {
        return uint256(1) << abi.decode(payload, (uint8));
    }

    function _validate(bytes memory payload) internal virtual;

    function _apply(bytes memory payload) internal virtual;
}
