// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {MuseMaxxingToken} from "../src/MuseMaxxingToken.sol";

/// @notice Edge inputs the main suite does not pin: the zero address as a sender through an
/// allowance, the owner spending its own tokens through transferFrom, approvals that overwrite
/// rather than add, an allowance spent to exactly zero, and the largest amounts the types allow.
/// forge-config: default.fuzz.runs = 1000
contract MuseMaxxingTokenEdgeTest is Test {
    uint256 internal constant EXPECTED_SUPPLY = 1_000_000_000 * 1e18;

    address internal deployer = makeAddr("deployer");
    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");

    MuseMaxxingToken internal token;

    function setUp() public {
        vm.prank(deployer);
        token = new MuseMaxxingToken();
    }

    // ───────────────────────────── transferFrom edges ─────────────────────────────

    /// @dev The zero address can never be a source, even for zero tokens. The allowance update runs
    /// before the sender check, so the zero amount is refused as an invalid approver rather than as
    /// an invalid sender; either way nothing is minted from the zero address.
    function test_transferFromZeroSenderFails() public {
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InvalidApprover.selector, address(0)));
        token.transferFrom(address(0), bob, 0);
        assertEq(token.totalSupply(), EXPECTED_SUPPLY);
        assertEq(token.balanceOf(bob), 0);

        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, bob, 0, 1));
        token.transferFrom(address(0), bob, 1);
    }

    /// @dev An allowance does not open the zero address as a destination.
    function test_transferFromToZeroReceiverFails() public {
        vm.prank(deployer);
        token.approve(alice, 10e18);

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InvalidReceiver.selector, address(0)));
        token.transferFrom(deployer, address(0), 1e18);
        assertEq(token.allowance(deployer, alice), 10e18, "a failed transferFrom spent the allowance");
        assertEq(token.balanceOf(deployer), EXPECTED_SUPPLY);
    }

    /// @dev A transferFrom of zero needs no allowance and moves nothing.
    function test_transferFromOfZeroNeedsNoAllowance() public {
        vm.prank(bob);
        assertTrue(token.transferFrom(deployer, bob, 0));
        assertEq(token.balanceOf(deployer), EXPECTED_SUPPLY);
        assertEq(token.balanceOf(bob), 0);
        assertEq(token.allowance(deployer, bob), 0);
    }

    /// @dev OpenZeppelin v5 makes no exception for the owner: spending your own tokens through
    /// transferFrom needs a self-allowance, exactly like any other spender.
    function test_ownerSpendingItselfThroughTransferFromNeedsAllowance() public {
        vm.prank(deployer);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, deployer, 0, 1));
        token.transferFrom(deployer, alice, 1);

        vm.prank(deployer);
        token.approve(deployer, 5e18);
        vm.prank(deployer);
        assertTrue(token.transferFrom(deployer, alice, 5e18));
        assertEq(token.balanceOf(alice), 5e18);
        assertEq(token.allowance(deployer, deployer), 0);
    }

    /// @dev Spending an allowance exactly leaves zero, and one more wei is refused.
    function test_allowanceSpentExactlyThenExhausted() public {
        vm.prank(deployer);
        token.approve(alice, 7e18);

        vm.prank(alice);
        assertTrue(token.transferFrom(deployer, bob, 7e18));
        assertEq(token.allowance(deployer, alice), 0);

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, alice, 0, 1));
        token.transferFrom(deployer, bob, 1);
    }

    /// @dev The infinite allowance is only the exact maximum: max minus one is a finite allowance
    /// that is decremented like any other.
    function test_maxMinusOneAllowanceIsFinite() public {
        vm.prank(deployer);
        token.approve(alice, type(uint256).max - 1);
        vm.prank(alice);
        token.transferFrom(deployer, bob, 1e18);
        assertEq(token.allowance(deployer, alice), type(uint256).max - 1 - 1e18);
    }

    /// @dev transferFrom emits a Transfer from the owner, not from the spender, and no Approval.
    function test_transferFromEmitsTransferFromOwnerOnly() public {
        vm.prank(deployer);
        token.approve(alice, 3e18);

        vm.recordLogs();
        vm.prank(alice);
        token.transferFrom(deployer, bob, 3e18);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        assertEq(logs.length, 1, "exactly one event");
        assertEq(logs[0].topics[0], IERC20.Transfer.selector);
        assertEq(address(uint160(uint256(logs[0].topics[1]))), deployer);
        assertEq(address(uint160(uint256(logs[0].topics[2]))), bob);
        assertEq(abi.decode(logs[0].data, (uint256)), 3e18);
    }

    // ───────────────────────────── approve edges ─────────────────────────────

    /// @dev approve sets, it does not add: two approvals leave the second value.
    function test_approveOverwritesInsteadOfAdding() public {
        vm.startPrank(deployer);
        token.approve(alice, 10e18);
        token.approve(alice, 4e18);
        vm.stopPrank();
        assertEq(token.allowance(deployer, alice), 4e18);

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, alice, 4e18, 5e18));
        token.transferFrom(deployer, bob, 5e18);
    }

    /// @dev Approving zero revokes.
    function test_approveZeroRevokes() public {
        vm.startPrank(deployer);
        token.approve(alice, 10e18);
        token.approve(alice, 0);
        vm.stopPrank();
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, alice, 0, 1));
        token.transferFrom(deployer, bob, 1);
    }

    /// @dev An allowance above the balance is recorded as given; the balance still caps the spend.
    function test_allowanceMayExceedBalanceButBalanceCapsTheSpend() public {
        vm.prank(alice);
        token.approve(bob, EXPECTED_SUPPLY);
        assertEq(token.allowance(alice, bob), EXPECTED_SUPPLY);
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, alice, 0, 1));
        token.transferFrom(alice, bob, 1);
    }

    /// @dev An empty account can approve; the allowance is independent of the balance.
    function test_emptyAccountCanApprove() public {
        vm.prank(bob);
        assertTrue(token.approve(alice, 1e18));
        assertEq(token.allowance(bob, alice), 1e18);
    }

    // ───────────────────────────── largest amounts ─────────────────────────────

    function test_transferOfTheWholeSupplyMovesEverything() public {
        vm.prank(deployer);
        assertTrue(token.transfer(alice, EXPECTED_SUPPLY));
        assertEq(token.balanceOf(deployer), 0);
        assertEq(token.balanceOf(alice), EXPECTED_SUPPLY);

        vm.prank(deployer);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, deployer, 0, 1));
        token.transfer(alice, 1);
    }

    function test_transferOfMaxUintFails() public {
        vm.prank(deployer);
        vm.expectRevert(
            abi.encodeWithSelector(
                IERC20Errors.ERC20InsufficientBalance.selector, deployer, EXPECTED_SUPPLY, type(uint256).max
            )
        );
        token.transfer(alice, type(uint256).max);
    }

    /// @dev One wei of MAXX is the smallest unit and moves exactly.
    function test_oneWeiTransfer() public {
        vm.prank(deployer);
        token.transfer(alice, 1);
        assertEq(token.balanceOf(alice), 1);
        assertEq(token.balanceOf(deployer), EXPECTED_SUPPLY - 1);
    }

    /// @dev Two deployments are independent: each mints its own supply to its own deployer, and a
    /// balance on one says nothing about the other.
    function test_independentDeploymentsDoNotShareState() public {
        vm.prank(alice);
        MuseMaxxingToken other = new MuseMaxxingToken();
        assertEq(other.balanceOf(alice), EXPECTED_SUPPLY);
        assertEq(other.balanceOf(deployer), 0);
        assertEq(token.balanceOf(alice), 0);
        assertEq(other.totalSupply(), EXPECTED_SUPPLY);
        assertEq(token.totalSupply(), EXPECTED_SUPPLY);
    }

    /// @dev The creation code takes no constructor arguments, so the bytes the manifest attests are
    /// exactly `type(...).creationCode` and a CREATE2 address can be predicted from them alone.
    function test_creationCodeHasNoConstructorArguments() public {
        bytes memory code = type(MuseMaxxingToken).creationCode;
        bytes32 salt = bytes32(uint256(42));
        address predicted =
            address(uint160(uint256(keccak256(abi.encodePacked(bytes1(0xff), address(this), salt, keccak256(code))))));
        MuseMaxxingToken deployed = new MuseMaxxingToken{salt: salt}();
        assertEq(address(deployed), predicted);
        assertEq(deployed.balanceOf(address(this)), EXPECTED_SUPPLY);
    }

    // ───────────────────────────── fuzzed properties ─────────────────────────────

    /// @dev A transfer then a transfer back is a round trip: both balances return to where they were.
    function testFuzz_transferRoundTrip(uint256 amount) public {
        amount = bound(amount, 0, EXPECTED_SUPPLY);
        vm.prank(deployer);
        token.transfer(alice, amount);
        vm.prank(alice);
        token.transfer(deployer, amount);
        assertEq(token.balanceOf(deployer), EXPECTED_SUPPLY);
        assertEq(token.balanceOf(alice), 0);
    }

    /// @dev A finite allowance decreases by exactly the amount spent, whatever the amount.
    function testFuzz_finiteAllowanceDecreasesByExactlyTheSpend(uint256 allowed, uint256 spent) public {
        allowed = bound(allowed, 0, type(uint256).max - 1);
        spent = bound(spent, 0, allowed < EXPECTED_SUPPLY ? allowed : EXPECTED_SUPPLY);
        vm.prank(deployer);
        token.approve(alice, allowed);
        vm.prank(alice);
        assertTrue(token.transferFrom(deployer, bob, spent));
        assertEq(token.allowance(deployer, alice), allowed - spent);
        assertEq(token.balanceOf(bob), spent);
    }

    /// @dev Any spend above a finite allowance reverts with the exact allowance in the error.
    function testFuzz_spendAboveFiniteAllowanceReverts(uint256 allowed, uint256 excess) public {
        allowed = bound(allowed, 0, EXPECTED_SUPPLY);
        excess = bound(excess, 1, type(uint256).max - allowed);
        vm.prank(deployer);
        token.approve(alice, allowed);
        vm.prank(alice);
        vm.expectRevert(
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, alice, allowed, allowed + excess)
        );
        token.transferFrom(deployer, bob, allowed + excess);
        assertEq(token.allowance(deployer, alice), allowed);
    }

    /// @dev Approvals are idempotent: approving the same value twice is the same as once.
    function testFuzz_approveIsIdempotent(uint256 amount) public {
        vm.startPrank(deployer);
        token.approve(alice, amount);
        token.approve(alice, amount);
        vm.stopPrank();
        assertEq(token.allowance(deployer, alice), amount);
    }

    /// @dev Approvals of one spender never touch another spender's allowance or any balance.
    function testFuzz_approveDoesNotTouchBalancesOrOtherSpenders(uint256 a, uint256 b) public {
        vm.startPrank(deployer);
        token.approve(alice, a);
        token.approve(bob, b);
        vm.stopPrank();
        assertEq(token.allowance(deployer, alice), a);
        assertEq(token.allowance(deployer, bob), b);
        assertEq(token.allowance(alice, deployer), 0);
        assertEq(token.balanceOf(deployer), EXPECTED_SUPPLY);
        assertEq(token.balanceOf(alice), 0);
        assertEq(token.balanceOf(bob), 0);
    }
}
