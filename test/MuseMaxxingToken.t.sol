// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {VmSafe} from "forge-std/Vm.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {MuseMaxxingToken} from "../src/MuseMaxxingToken.sol";
import {DeployMuseMaxxing} from "../script/DeployMuseMaxxing.s.sol";

/// @notice Stands in for the launch factory: deploys the token's creation code through CREATE2 so
/// the constructor's `msg.sender` is this contract, exactly as ProjectFactory.launchCustom does.
contract Create2Deployer {
    function deploy(bytes memory code, bytes32 salt) external returns (address deployed) {
        assembly ("memory-safe") {
            deployed := create2(0, add(code, 32), mload(code), salt)
        }
        require(deployed != address(0) && deployed.code.length > 0, "constructor failed");
    }

    function send(IERC20 token, address to, uint256 amount) external returns (bool) {
        return token.transfer(to, amount);
    }
}

contract MuseMaxxingTokenTest is Test {
    uint256 internal constant EXPECTED_SUPPLY = 1_000_000_000 * 1e18;

    address internal deployer = makeAddr("deployer");
    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");

    MuseMaxxingToken internal token;

    function setUp() public {
        vm.prank(deployer);
        token = new MuseMaxxingToken();
    }

    // ───────────────────────────── metadata ─────────────────────────────

    function test_metadata() public view {
        assertEq(token.name(), "MuseMaxxing");
        assertEq(token.symbol(), "MAXX");
        assertEq(token.decimals(), 18);
        assertEq(token.NAME(), "MuseMaxxing");
        assertEq(token.SYMBOL(), "MAXX");
        assertEq(token.DECIMALS(), 18);
    }

    function test_supplyConstantsAgree() public view {
        assertEq(token.SUPPLY_WHOLE_TOKENS(), 1_000_000_000);
        assertEq(token.TOTAL_SUPPLY(), EXPECTED_SUPPLY);
        assertEq(token.TOTAL_SUPPLY(), token.SUPPLY_WHOLE_TOKENS() * 10 ** token.DECIMALS());
    }

    /// @dev The launch manifest records the contract under its Solidity name, at most 32 characters.
    function test_contractNameFitsTheManifest() public pure {
        assertLe(bytes("MuseMaxxingToken").length, 32);
    }

    // ───────────────────────────── minting ─────────────────────────────

    function test_mintsTheWholeSupplyOnceToTheDeployer() public view {
        assertEq(token.totalSupply(), EXPECTED_SUPPLY);
        assertEq(token.balanceOf(deployer), EXPECTED_SUPPLY);
        assertEq(token.balanceOf(address(this)), 0);
    }

    function test_constructorEmitsASingleMintTransfer() public {
        vm.recordLogs();
        vm.prank(deployer);
        MuseMaxxingToken fresh = new MuseMaxxingToken();
        VmSafe.Log[] memory logs = vm.getRecordedLogs();
        assertEq(logs.length, 1, "exactly one event");
        assertEq(logs[0].emitter, address(fresh));
        assertEq(logs[0].topics[0], IERC20.Transfer.selector);
        assertEq(address(uint160(uint256(logs[0].topics[1]))), address(0));
        assertEq(address(uint160(uint256(logs[0].topics[2]))), deployer);
        assertEq(abi.decode(logs[0].data, (uint256)), EXPECTED_SUPPLY);
    }

    function testFuzz_anyDeployerReceivesTheWholeSupply(address anyDeployer) public {
        vm.assume(anyDeployer != address(0));
        vm.assume(anyDeployer.code.length == 0);
        vm.prank(anyDeployer);
        MuseMaxxingToken fresh = new MuseMaxxingToken();
        assertEq(fresh.totalSupply(), EXPECTED_SUPPLY);
        assertEq(fresh.balanceOf(anyDeployer), EXPECTED_SUPPLY);
    }

    /// @dev The launch deploys the creation code through CREATE2 from the factory; the factory must
    /// end up holding the whole supply and be able to pay it out, with no constructor arguments.
    function test_create2DeploymentMintsToTheFactory() public {
        Create2Deployer factory = new Create2Deployer();
        address deployed = factory.deploy(type(MuseMaxxingToken).creationCode, bytes32(uint256(1)));
        MuseMaxxingToken launched = MuseMaxxingToken(deployed);
        assertEq(launched.totalSupply(), EXPECTED_SUPPLY);
        assertEq(launched.balanceOf(address(factory)), EXPECTED_SUPPLY);

        uint256 swarm = EXPECTED_SUPPLY / 10;
        assertTrue(factory.send(launched, alice, swarm));
        assertEq(launched.balanceOf(alice), swarm);
        assertEq(launched.balanceOf(address(factory)), EXPECTED_SUPPLY - swarm);
        assertEq(launched.totalSupply(), EXPECTED_SUPPLY);
    }

    function test_deployScriptFunctionDeploysTheToken() public {
        DeployMuseMaxxing script = new DeployMuseMaxxing();
        MuseMaxxingToken deployed = script.deploy();
        assertEq(deployed.totalSupply(), EXPECTED_SUPPLY);
        assertEq(deployed.balanceOf(address(script)), EXPECTED_SUPPLY);
        assertEq(deployed.name(), "MuseMaxxing");
        assertEq(deployed.symbol(), "MAXX");
    }

    // ───────────────────────────── transfers ─────────────────────────────

    function test_transferMovesExactlyTheAmount() public {
        uint256 amount = 1_234_567e18;
        vm.prank(deployer);
        vm.expectEmit(true, true, true, true, address(token));
        emit IERC20.Transfer(deployer, alice, amount);
        assertTrue(token.transfer(alice, amount));
        assertEq(token.balanceOf(alice), amount);
        assertEq(token.balanceOf(deployer), EXPECTED_SUPPLY - amount);
        assertEq(token.totalSupply(), EXPECTED_SUPPLY);
    }

    function test_transferOfZeroSucceeds() public {
        vm.prank(alice);
        assertTrue(token.transfer(bob, 0));
        assertEq(token.balanceOf(bob), 0);
    }

    function test_transferToSelfKeepsBalance() public {
        vm.prank(deployer);
        assertTrue(token.transfer(deployer, 5e18));
        assertEq(token.balanceOf(deployer), EXPECTED_SUPPLY);
    }

    function test_transferFailsOnInsufficientBalance() public {
        vm.prank(deployer);
        token.transfer(alice, 10e18);

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, alice, 10e18, 11e18));
        token.transfer(bob, 11e18);
        assertEq(token.balanceOf(alice), 10e18);
        assertEq(token.balanceOf(bob), 0);
    }

    function test_transferFromEmptyAccountFails() public {
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, bob, 0, 1));
        token.transfer(alice, 1);
    }

    function test_transferToZeroAddressFails() public {
        vm.prank(deployer);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InvalidReceiver.selector, address(0)));
        token.transfer(address(0), 1);
        assertEq(token.balanceOf(deployer), EXPECTED_SUPPLY);
    }

    function testFuzz_transferConservesSupply(address to, uint256 amount) public {
        vm.assume(to != address(0));
        amount = bound(amount, 0, EXPECTED_SUPPLY);
        vm.prank(deployer);
        assertTrue(token.transfer(to, amount));
        if (to == deployer) {
            assertEq(token.balanceOf(deployer), EXPECTED_SUPPLY);
        } else {
            assertEq(token.balanceOf(to), amount);
            assertEq(token.balanceOf(deployer), EXPECTED_SUPPLY - amount);
        }
        assertEq(token.totalSupply(), EXPECTED_SUPPLY);
    }

    function testFuzz_transferAboveBalanceAlwaysReverts(uint256 amount) public {
        amount = bound(amount, EXPECTED_SUPPLY + 1, type(uint256).max);
        vm.prank(deployer);
        vm.expectRevert(
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, deployer, EXPECTED_SUPPLY, amount)
        );
        token.transfer(alice, amount);
    }

    /// @dev A chain of random transfers between a handful of holders never changes the sum of balances.
    function testFuzz_randomTransferChainConservesSupply(uint256 seed) public {
        address[4] memory holders = [deployer, alice, bob, makeAddr("carol")];
        for (uint256 i; i < 16; ++i) {
            uint256 r = uint256(keccak256(abi.encode(seed, i)));
            address from = holders[r % 4];
            address to = holders[(r >> 8) % 4];
            uint256 amount = (r >> 16) % (token.balanceOf(from) + 1);
            vm.prank(from);
            assertTrue(token.transfer(to, amount));
        }
        uint256 sum;
        for (uint256 i; i < 4; ++i) {
            sum += token.balanceOf(holders[i]);
        }
        assertEq(sum, EXPECTED_SUPPLY);
        assertEq(token.totalSupply(), EXPECTED_SUPPLY);
    }

    // ───────────────────────────── allowances ─────────────────────────────

    function test_approveAndTransferFrom() public {
        vm.prank(deployer);
        token.transfer(alice, 100e18);

        vm.prank(alice);
        vm.expectEmit(true, true, true, true, address(token));
        emit IERC20.Approval(alice, bob, 60e18);
        assertTrue(token.approve(bob, 60e18));
        assertEq(token.allowance(alice, bob), 60e18);

        vm.prank(bob);
        assertTrue(token.transferFrom(alice, bob, 40e18));
        assertEq(token.balanceOf(alice), 60e18);
        assertEq(token.balanceOf(bob), 40e18);
        assertEq(token.allowance(alice, bob), 20e18);
    }

    function test_transferFromFailsWithoutAllowance() public {
        vm.prank(deployer);
        token.transfer(alice, 100e18);

        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, bob, 0, 1));
        token.transferFrom(alice, bob, 1);
        assertEq(token.balanceOf(alice), 100e18);
    }

    function test_transferFromFailsAboveAllowance() public {
        vm.prank(deployer);
        token.transfer(alice, 100e18);
        vm.prank(alice);
        token.approve(bob, 10e18);

        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, bob, 10e18, 11e18));
        token.transferFrom(alice, bob, 11e18);
        assertEq(token.allowance(alice, bob), 10e18);
    }

    function test_transferFromFailsAboveBalanceEvenWithAllowance() public {
        vm.prank(deployer);
        token.transfer(alice, 5e18);
        vm.prank(alice);
        token.approve(bob, type(uint256).max);

        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, alice, 5e18, 6e18));
        token.transferFrom(alice, bob, 6e18);
    }

    function test_infiniteAllowanceIsNotDecremented() public {
        vm.prank(deployer);
        token.approve(alice, type(uint256).max);
        vm.prank(alice);
        token.transferFrom(deployer, bob, 1e18);
        assertEq(token.allowance(deployer, alice), type(uint256).max);
    }

    function test_approveZeroSpenderFails() public {
        vm.prank(deployer);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InvalidSpender.selector, address(0)));
        token.approve(address(0), 1);
    }

    // ───────────────────────────── no privileged surface ─────────────────────────────

    /// @dev The token has no owner, no minter and no admin. Every common mint or admin selector,
    /// from a stranger and from the deployer alike, must be rejected and leave the supply where it is.
    function test_noMintOrAdminSelectorExists() public {
        string[12] memory signatures = [
            "mint(address,uint256)",
            "mint(uint256)",
            "mint()",
            "issue(uint256)",
            "setOwner(address)",
            "transferOwnership(address)",
            "upgradeTo(address)",
            "initialize(address)",
            "unpause()",
            "setMinter(address)",
            "owner()",
            "renounceOwnership()"
        ];
        address attacker = makeAddr("attacker");
        for (uint256 i; i < signatures.length; ++i) {
            bytes memory data = abi.encodeWithSignature(signatures[i], attacker, type(uint128).max);
            vm.prank(attacker);
            (bool ok,) = address(token).call(data);
            assertFalse(ok, signatures[i]);
            vm.prank(deployer);
            (ok,) = address(token).call(data);
            assertFalse(ok, signatures[i]);
            assertEq(token.totalSupply(), EXPECTED_SUPPLY, signatures[i]);
            assertEq(token.balanceOf(attacker), 0, signatures[i]);
        }
    }

    /// @dev Nobody can move or freeze a holder's balance but the holder, not even the deployer.
    function test_noPrivilegedCallMovesOrFreezesAHolder() public {
        vm.prank(deployer);
        token.transfer(alice, 1_000e18);
        string[12] memory signatures = [
            "pause()",
            "blacklist(address)",
            "blocklist(address)",
            "freeze(address)",
            "freezeAccount(address)",
            "setBlacklist(address,bool)",
            "setBlocked(address,bool)",
            "lock(address)",
            "disableTransfers()",
            "setTransfersEnabled(bool)",
            "burnFrom(address,uint256)",
            "seize(address)"
        ];
        for (uint256 i; i < signatures.length; ++i) {
            vm.prank(deployer);
            (bool ok,) = address(token).call(abi.encodeWithSignature(signatures[i], alice, true));
            assertFalse(ok, signatures[i]);
        }
        vm.prank(deployer);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, deployer, 0, 1));
        token.transferFrom(alice, deployer, 1);

        assertEq(token.balanceOf(alice), 1_000e18);
        vm.prank(alice);
        assertTrue(token.transfer(bob, 500e18));
        assertEq(token.balanceOf(bob), 500e18);
    }

    function test_noEtherAccepted() public {
        vm.deal(alice, 1 ether);
        vm.prank(alice);
        (bool ok,) = address(token).call{value: 1 ether}("");
        assertFalse(ok);
        assertEq(address(token).balance, 0);
    }

    /// @dev Mirrors the launch floor: the runtime must contain no DELEGATECALL, CALLCODE or SELFDESTRUCT.
    function test_runtimeHasNoDelegatecallCallcodeOrSelfdestruct() public view {
        bytes memory runtime = address(token).code;
        assertGt(runtime.length, 0);
        assertLe(runtime.length, 24_576, "runtime exceeds EIP-170");
        for (uint256 i; i < runtime.length; ++i) {
            uint8 op = uint8(runtime[i]);
            if (op >= 0x60 && op <= 0x7F) {
                i += (op - 0x5F);
                continue;
            }
            assertTrue(op != 0xF4, "DELEGATECALL");
            assertTrue(op != 0xF2, "CALLCODE");
            assertTrue(op != 0xFF, "SELFDESTRUCT");
        }
    }
}
