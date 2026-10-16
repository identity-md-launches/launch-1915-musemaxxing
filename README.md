# MuseMaxxing (MAXX)

A fixed-supply ERC-20 token for the IdentityMD custom-token launch on Ethereum mainnet.

| Parameter          | Value                                                        |
| ------------------ | ------------------------------------------------------------ |
| Solidity contract  | `MuseMaxxingToken` (`src/MuseMaxxingToken.sol`)              |
| `name()`           | `MuseMaxxing`                                                |
| `symbol()`         | `MAXX`                                                       |
| `decimals()`       | `18`                                                         |
| Total supply       | `1_000_000_000 * 10**18` = `1000000000000000000000000000` minor units |
| Minting            | Once, in the constructor, the whole supply to `msg.sender` (the deployer) |
| Constructor args   | None                                                         |
| Owner / admin      | None                                                         |
| Compiler           | `solc 0.8.26`, optimizer on (200 runs), `evm_version = cancun`, `bytecode_hash = "none"` |
| Base library       | OpenZeppelin Contracts v5.1.0 `ERC20` (vendored under `lib/openzeppelin`) |

## Behaviour

- The constructor mints `TOTAL_SUPPLY` to `msg.sender` and emits one `Transfer(address(0), deployer, TOTAL_SUPPLY)`.
  Nothing else can ever mint: there is no `mint`, no minter role, no owner and no upgrade path.
- Transfers are plain ERC-20: no fee, no burn on transfer, no reflections, no pause, no blocklist,
  no transfer limits. Every transfer and `transferFrom` moves exactly the amount requested, so the
  launch flows (factory to distributor, pool seed, claims, swaps) arrive whole.
- Standard OpenZeppelin v5 behaviour applies: transfers to the zero address, approvals of the
  zero spender, transfers above balance and `transferFrom` above allowance revert with the
  ERC-6093 custom errors. An allowance of `type(uint256).max` is never decremented.
- The contract holds no ETH and has no `receive` or `fallback`; plain ETH sends revert.
- The runtime contains no `DELEGATECALL`, `CALLCODE` or `SELFDESTRUCT` (asserted in the tests).

All named constants are public on the contract: `NAME`, `SYMBOL`, `DECIMALS`,
`SUPPLY_WHOLE_TOKENS` (1,000,000,000) and `TOTAL_SUPPLY`.

## Assumptions

- "Deployer" means the `msg.sender` of the constructor. On the IdentityMD launch the ProjectFactory
  deploys the token through `launchCustom` (CREATE2), so the factory receives the whole supply and
  then pays it out: 10% to the launch's MerkleDistributor, 80% to seed the Uniswap v4 pool and the
  remaining 10% to the requester's remainder address. The token does not need to know any of those
  addresses, because it exempts nothing and taxes nothing, so it takes no constructor arguments.
- The brief asks for nothing beyond a fixed supply, so no burn, permit (EIP-2612), vote, pause or
  tax features were added. Holders who want to burn can send to a burn address they choose; the
  supply figure then still reports the minted amount.
- No value in the brief was left open to choose, so there are no chosen-by-the-builder numbers.

## Deployment parameters (for the launch manifest step)

The launch manifest is written by the manifest step after this work is accepted, not here. The
values it needs from the token are:

- `token.contract`: `MuseMaxxingToken`
- `token.name`: `MuseMaxxing`
- `token.symbol`: `MAXX`
- `token.decimals`: `18`
- `token.constructorArgs`: `[]`
- `token.totalSupply`: `1000000000000000000000000000`
- Application contracts: none (`contracts: []`)

Launch-decided values that the token does not depend on: chain id 1, pair currency IMD
(`0xd34a99bc0f67ae1bbd63c660e6d0b0dd03e263b7`), pool fee 12500, tick spacing 60, and the requester's
economics (`poolBps` 8000, `initialMarketCapWei` 3500 IMD, remainder to
`0x206f5dbf4f135c6183b5a5b99327fa0be34cb4d9`).

## After launch

Nothing to configure. The token has no owner-settable values, no setters and no privileged
functions. There is no operational key to hold or rotate.

## Operational responsibilities

- **Requester**: receives the remainder share at `economics.remainderTo` and is responsible for
  the custody of that wallet. No further action on the token is possible or required.
- **IdentityMD deployer**: deploys through the factory and runs the launch flows. This repository
  contains no broadcast, key handling or `launch.json`; `script/DeployMuseMaxxing.s.sol` is only a
  local or testnet helper (`forge script script/DeployMuseMaxxing.s.sol --broadcast ...`) and is not
  part of the launch. Whoever broadcasts it becomes the deployer and receives the full supply.
- **Explorer verification**: belongs to the network's deployer after launch
  (`forge verify-contract <address> src/MuseMaxxingToken.sol:MuseMaxxingToken` with the pinned
  compiler settings; there are no constructor arguments to encode).
- **Audit**: the tests here are not a security audit. The token is a thin wrapper over
  OpenZeppelin's audited `ERC20`, but an independent review before release remains the policy for
  anything that holds other people's funds.

## Repository layout

```
foundry.toml                      compiler pins and build settings (root project)
remappings.txt                    forge-std and @openzeppelin/contracts remappings
src/MuseMaxxingToken.sol          the token
script/DeployMuseMaxxing.s.sol    local deploy helper; deploy() is tested directly
test/MuseMaxxingToken.t.sol       unit and fuzz tests
lib/forge-std                     forge-std v1.9.7, vendored as plain files
lib/openzeppelin                  OpenZeppelin Contracts v5.1.0 (contracts/ only), vendored as plain files
```

Both libraries are committed as ordinary files, not git submodules, so the project builds offline.

## Build and test

```
forge build
forge test
forge fmt --check
```

The tests read no environment variables and do not depend on the calling address, so they pass in
any order and in parallel. They were run with the verifier's fuzz seed
(`FOUNDRY_FUZZ_SEED=0x2ce03531746f0a957c1a3b2a8bc1de3c758c8236bb60d2736a279e744bed4ce7`).

Test coverage, in brief:

- metadata (`name`, `symbol`, `decimals`) and the supply constants;
- the single constructor mint to the deployer, its `Transfer` event, a fuzzed deployer, a CREATE2
  deployment from a factory-like contract that then pays out a share, and the deploy script's
  `deploy()`;
- transfer success paths (exact amounts, zero, self) and failure paths (insufficient balance,
  empty account, zero receiver), including fuzzed conservation of supply over random transfer chains;
- allowances: approve/transferFrom, missing or insufficient allowance, balance limit under an
  allowance, infinite allowance not decremented, zero spender;
- the absence of any mint or admin surface, the absence of any call that moves or freezes a holder,
  no ETH acceptance, and an opcode scan of the runtime for `DELEGATECALL`, `CALLCODE` and `SELFDESTRUCT`.
