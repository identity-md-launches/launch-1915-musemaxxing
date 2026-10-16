// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @title MuseMaxxing (MAXX)
/// @notice A fixed-supply ERC-20. The whole supply of 1,000,000,000 MAXX (18 decimals) is minted
/// once, in the constructor, to the deployer. Nothing can mint afterwards: there is no owner, no
/// minter role, no pause, no blocklist, no fee on transfer and no upgrade path. Every transfer moves
/// exactly the amount requested.
/// @dev The deployer is `msg.sender` of the constructor. On the IdentityMD launch that is the
/// ProjectFactory, which distributes the supply (swarm share, pool seed, requester remainder). The
/// contract takes no constructor arguments, so its creation code is the same on every chain.
contract MuseMaxxingToken is ERC20 {
    /// @notice Token name, as `name()` returns it.
    string public constant NAME = "MuseMaxxing";

    /// @notice Token symbol, as `symbol()` returns it.
    string public constant SYMBOL = "MAXX";

    /// @notice Number of decimals, as `decimals()` returns it.
    uint8 public constant DECIMALS = 18;

    /// @notice Whole tokens minted at deployment: one billion.
    uint256 public constant SUPPLY_WHOLE_TOKENS = 1_000_000_000;

    /// @notice The entire supply in minor units (1,000,000,000 * 10^18), minted once in the constructor.
    uint256 public constant TOTAL_SUPPLY = SUPPLY_WHOLE_TOKENS * 10 ** DECIMALS;

    /// @notice Mints the full fixed supply to the deployer (`msg.sender`).
    /// @dev Emits a single ERC-20 `Transfer(address(0), msg.sender, TOTAL_SUPPLY)`.
    constructor() ERC20(NAME, SYMBOL) {
        _mint(msg.sender, TOTAL_SUPPLY);
    }

    /// @inheritdoc ERC20
    function decimals() public pure override returns (uint8) {
        return DECIMALS;
    }
}
