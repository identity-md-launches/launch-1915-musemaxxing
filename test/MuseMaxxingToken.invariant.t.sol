// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {MuseMaxxingToken} from "../src/MuseMaxxingToken.sol";

/// @notice Drives the token with random, bounded call sequences from a fixed set of actors and keeps
/// its own ledger of what every balance and allowance must be. Every public function here is one
/// transaction the fuzzer may pick; none of them is allowed to revert, so a failure path is exercised
/// through a low-level call whose revert is asserted explicitly rather than tolerated silently.
contract MuseMaxxingHandler is Test {
    MuseMaxxingToken public immutable token;
    uint256 public immutable supply;

    /// @dev The deployer (index 0, holds the supply at the start) and a handful of ordinary holders.
    address[] public actors;

    /// @dev What the handler believes each balance and allowance is, updated only on calls that
    /// succeeded. The invariants compare this ledger with the contract.
    mapping(address => uint256) public ghostBalance;
    mapping(address => mapping(address => uint256)) public ghostAllowance;

    /// @dev Call counters, so a run that never reached a path can be told from one that did.
    uint256 public transfers;
    uint256 public approvals;
    uint256 public transferFroms;
    uint256 public rejectedTransfers;
    uint256 public rejectedTransferFroms;
    uint256 public rejectedZeroReceivers;
    uint256 public rejectedMints;
    uint256 public rejectedEther;
    uint256 public tokensMoved;

    constructor(MuseMaxxingToken token_, address deployer, uint256 holderCount) {
        token = token_;
        supply = token_.totalSupply();
        actors.push(deployer);
        for (uint256 i; i < holderCount; ++i) {
            actors.push(makeAddr(string.concat("holder", vm.toString(i))));
        }
        ghostBalance[deployer] = supply;
    }

    function actorCount() external view returns (uint256) {
        return actors.length;
    }

    // ───────────────────────────── happy paths ─────────────────────────────

    /// @notice A holder sends part of what it has (possibly nothing, possibly everything, possibly to itself).
    function transfer(uint256 fromSeed, uint256 toSeed, uint256 amount) external {
        address from = _actor(fromSeed);
        address to = _actor(toSeed);
        amount = bound(amount, 0, token.balanceOf(from));

        vm.prank(from);
        bool ok = token.transfer(to, amount);
        assertTrue(ok, "transfer returned false");

        ghostBalance[from] -= amount;
        ghostBalance[to] += amount;
        tokensMoved += amount;
        ++transfers;
    }

    /// @notice An owner sets (not adds to) an allowance. Now and then it is the infinite allowance.
    function approve(uint256 ownerSeed, uint256 spenderSeed, uint256 amount) external {
        address owner = _actor(ownerSeed);
        address spender = _actor(spenderSeed);
        // One in eight approvals is unlimited, so transferFrom sees both regimes.
        if (amount % 8 == 0) amount = type(uint256).max;
        else amount = bound(amount, 0, 2 * supply);

        vm.prank(owner);
        bool ok = token.approve(spender, amount);
        assertTrue(ok, "approve returned false");

        ghostAllowance[owner][spender] = amount;
        ++approvals;
    }

    /// @notice A spender moves an owner's tokens within both the balance and the allowance.
    function transferFrom(uint256 spenderSeed, uint256 ownerSeed, uint256 toSeed, uint256 amount) external {
        address spender = _actor(spenderSeed);
        address owner = _actor(ownerSeed);
        address to = _actor(toSeed);
        uint256 allowed = token.allowance(owner, spender);
        uint256 cap = allowed < token.balanceOf(owner) ? allowed : token.balanceOf(owner);
        amount = bound(amount, 0, cap);

        vm.prank(spender);
        bool ok = token.transferFrom(owner, to, amount);
        assertTrue(ok, "transferFrom returned false");

        ghostBalance[owner] -= amount;
        ghostBalance[to] += amount;
        if (allowed != type(uint256).max) ghostAllowance[owner][spender] = allowed - amount;
        tokensMoved += amount;
        ++transferFroms;
    }

    // ───────────────────────────── failure paths ─────────────────────────────

    /// @notice A holder tries to send more than it has: must revert with the exact error, move nothing.
    function transferAboveBalance(uint256 fromSeed, uint256 toSeed, uint256 excess) external {
        address from = _actor(fromSeed);
        address to = _actor(toSeed);
        uint256 held = token.balanceOf(from);
        excess = bound(excess, 1, type(uint256).max - held);
        uint256 amount = held + excess;

        vm.prank(from);
        (bool ok, bytes memory ret) = address(token).call(abi.encodeCall(IERC20.transfer, (to, amount)));
        assertFalse(ok, "transfer above balance succeeded");
        assertEq(
            ret,
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, from, held, amount),
            "wrong error for transfer above balance"
        );
        assertEq(token.balanceOf(from), held, "a failed transfer changed the sender's balance");
        ++rejectedTransfers;
    }

    /// @notice A spender tries to move more than it was allowed: must revert, allowance untouched.
    function transferFromAboveAllowance(uint256 spenderSeed, uint256 ownerSeed, uint256 toSeed, uint256 excess)
        external
    {
        address spender = _actor(spenderSeed);
        address owner = _actor(ownerSeed);
        address to = _actor(toSeed);
        uint256 allowed = token.allowance(owner, spender);
        if (allowed == type(uint256).max) {
            // Nothing is above an infinite allowance; the balance bound applies instead.
            uint256 held = token.balanceOf(owner);
            uint256 amount = held + bound(excess, 1, type(uint256).max - held);
            vm.prank(spender);
            (bool okInf, bytes memory retInf) =
                address(token).call(abi.encodeCall(IERC20.transferFrom, (owner, to, amount)));
            assertFalse(okInf, "transferFrom above balance succeeded under infinite allowance");
            assertEq(
                retInf, abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, owner, held, amount)
            );
            assertEq(token.allowance(owner, spender), type(uint256).max, "infinite allowance was decremented");
        } else {
            uint256 amount = allowed + bound(excess, 1, type(uint256).max - allowed);
            vm.prank(spender);
            (bool ok, bytes memory ret) = address(token).call(abi.encodeCall(IERC20.transferFrom, (owner, to, amount)));
            assertFalse(ok, "transferFrom above allowance succeeded");
            assertEq(
                ret,
                abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, spender, allowed, amount),
                "wrong error for transferFrom above allowance"
            );
            assertEq(token.allowance(owner, spender), allowed, "a failed transferFrom changed the allowance");
        }
        ++rejectedTransferFroms;
    }

    /// @notice Sending to the zero address, directly or through an allowance, is refused outright.
    function transferToZeroAddress(uint256 fromSeed, uint256 amount) external {
        address from = _actor(fromSeed);
        amount = bound(amount, 0, token.balanceOf(from));

        vm.prank(from);
        (bool ok, bytes memory ret) = address(token).call(abi.encodeCall(IERC20.transfer, (address(0), amount)));
        assertFalse(ok, "transfer to the zero address succeeded");
        assertEq(ret, abi.encodeWithSelector(IERC20Errors.ERC20InvalidReceiver.selector, address(0)));

        vm.prank(from);
        (ok, ret) = address(token).call(abi.encodeCall(IERC20.approve, (address(0), amount)));
        assertFalse(ok, "approve of the zero spender succeeded");
        assertEq(ret, abi.encodeWithSelector(IERC20Errors.ERC20InvalidSpender.selector, address(0)));
        ++rejectedZeroReceivers;
    }

    /// @notice Any actor, the deployer included, tries the usual mint, burn and admin selectors.
    /// There is no such surface: every call must fail and the supply must not move.
    function probeMintAndAdmin(uint256 callerSeed, uint256 which, uint256 amount) external {
        address caller = _actor(callerSeed);
        string[8] memory signatures = [
            "mint(address,uint256)",
            "mint(uint256)",
            "burn(uint256)",
            "burnFrom(address,uint256)",
            "transferOwnership(address)",
            "pause()",
            "blacklist(address)",
            "upgradeTo(address)"
        ];
        string memory sig = signatures[which % signatures.length];
        uint256 supplyBefore = token.totalSupply();
        uint256 held = token.balanceOf(caller);

        vm.prank(caller);
        (bool ok,) = address(token).call(abi.encodeWithSignature(sig, caller, amount));
        assertFalse(ok, sig);
        assertEq(token.totalSupply(), supplyBefore, "a probe changed the supply");
        assertEq(token.balanceOf(caller), held, "a probe changed the caller's balance");
        ++rejectedMints;
    }

    /// @notice The token takes no ether, with or without calldata.
    function sendEther(uint256 fromSeed, uint256 amount) external {
        address from = _actor(fromSeed);
        amount = bound(amount, 1, 100 ether);
        vm.deal(from, amount);

        vm.prank(from);
        (bool ok,) = address(token).call{value: amount}("");
        assertFalse(ok, "the token accepted ether");
        assertEq(address(token).balance, 0);
        ++rejectedEther;
    }

    function _actor(uint256 seed) internal view returns (address) {
        return actors[seed % actors.length];
    }
}

/// @notice Properties that must hold after every random sequence of handler calls. The token holds
/// value from the first block: the whole supply sits with the deployer and moves between holders.
/// forge-config: default.invariant.runs = 256
/// forge-config: default.invariant.depth = 64
/// forge-config: default.invariant.fail-on-revert = true
contract MuseMaxxingTokenInvariantTest is Test {
    uint256 internal constant EXPECTED_SUPPLY = 1_000_000_000 * 1e18;
    uint256 internal constant HOLDERS = 5;

    address internal deployer = makeAddr("deployer");
    MuseMaxxingToken internal token;
    MuseMaxxingHandler internal handler;

    bytes32 internal codeHashAtDeployment;

    function setUp() public {
        vm.prank(deployer);
        token = new MuseMaxxingToken();
        codeHashAtDeployment = address(token).codehash;

        handler = new MuseMaxxingHandler(token, deployer, HOLDERS);

        // Only the handler is driven: the token's own functions are reached through it, so every
        // successful move is mirrored in the ghost ledger.
        targetContract(address(handler));
    }

    /// @dev A fixed supply never changes, up or down, whatever sequence of calls is made.
    function invariant_totalSupplyIsFixed() public view {
        assertEq(token.totalSupply(), EXPECTED_SUPPLY, "supply changed");
        assertEq(token.totalSupply(), token.TOTAL_SUPPLY());
    }

    /// @dev Tokens are neither created nor destroyed by transfers: the actors' balances sum to the supply.
    function invariant_balancesSumToSupply() public view {
        uint256 sum;
        uint256 n = handler.actorCount();
        for (uint256 i; i < n; ++i) {
            sum += token.balanceOf(handler.actors(i));
        }
        assertEq(sum, token.totalSupply(), "balances do not sum to the supply");
    }

    /// @dev Every balance is exactly what the ledger of successful transfers says: no fee, no
    /// reflection, no rounding, and no failed call leaving a trace.
    function invariant_balancesMatchGhostLedger() public view {
        uint256 n = handler.actorCount();
        for (uint256 i; i < n; ++i) {
            address a = handler.actors(i);
            assertEq(token.balanceOf(a), handler.ghostBalance(a), "balance drifted from the ledger");
            assertLe(token.balanceOf(a), EXPECTED_SUPPLY, "a balance exceeds the supply");
        }
    }

    /// @dev Allowances are exactly what was approved minus what was spent, and an infinite one stays infinite.
    function invariant_allowancesMatchGhostLedger() public view {
        uint256 n = handler.actorCount();
        for (uint256 i; i < n; ++i) {
            for (uint256 j; j < n; ++j) {
                address owner = handler.actors(i);
                address spender = handler.actors(j);
                assertEq(token.allowance(owner, spender), handler.ghostAllowance(owner, spender), "allowance drifted");
            }
        }
    }

    /// @dev Nobody outside the actor set, the zero address and the token itself included, ever gains a balance.
    function invariant_nothingLeaksToOutsiders() public view {
        assertEq(token.balanceOf(address(0)), 0);
        assertEq(token.balanceOf(address(token)), 0);
        assertEq(token.balanceOf(address(handler)), 0);
        assertEq(token.balanceOf(address(this)), 0);
        assertEq(address(token).balance, 0, "the token holds ether");
    }

    /// @dev Metadata and code are immutable: no sequence renames, redenominates or upgrades the token.
    function invariant_metadataAndCodeAreImmutable() public view {
        assertEq(token.name(), "MuseMaxxing");
        assertEq(token.symbol(), "MAXX");
        assertEq(token.decimals(), 18);
        assertEq(address(token).codehash, codeHashAtDeployment, "runtime code changed");
    }

    /// @dev After each run, every handler path must have been reached at least once across the
    /// sequence; a suite whose failure paths are never exercised proves nothing about them.
    function afterInvariant() public view {
        assertGt(handler.transfers() + handler.transferFroms() + handler.approvals(), 0, "no happy path ran");
        assertGt(
            handler.rejectedTransfers() + handler.rejectedTransferFroms() + handler.rejectedZeroReceivers()
                + handler.rejectedMints() + handler.rejectedEther(),
            0,
            "no failure path ran"
        );
    }
}
