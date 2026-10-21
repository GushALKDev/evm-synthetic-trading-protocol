// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Script} from "forge-std/Script.sol";

import {TradingEngine} from "../../src/TradingEngine.sol";
import {TradingStorage} from "../../src/TradingStorage.sol";
import {PythChainlinkOracle} from "../../src/PythChainlinkOracle.sol";
import {DemoPyth} from "./DemoPyth.sol";
import {TestnetFaucet} from "./TestnetFaucet.sol";
import {TestnetPrices} from "./TestnetPrices.sol";

/**
 * @title SeedTrades
 * @author GushALKDev
 * @notice Opens the demo's seed trades from the deployer: both sides of BTC/USD and ETH/USD, with more open interest
 *         on one side of each pair, so funding flows and the Vault carries open PnL from the start
 * @dev Run with the account that ran DeployTestnet (it owns the faucet, which mints the collateral), right after it.
 *      A separate run on purpose: each trade carries a price stamped with the simulated block's timestamp, and the
 *      oracle rejects it once it is older than its maxPriceAge (30 s on the demo), so it should not wait behind the
 *      deployment transactions.
 *      If it reverts with StalePrice (a slow RPC) or PriceNotChainlinkAnswer (Chainlink published a new answer in
 *      between), run it again: a seed trade the deployer already holds (same pair and side) is skipped, so a rerun
 *      opens only the missing ones.
 *      After seeding, the Vault's PnL snapshot is no longer fresh, so deposits go through refreshAndDeposit.
 *
 *      Usage: forge script script/testnet/SeedTrades.s.sol --rpc-url $BASE_SEPOLIA_RPC_URL --account <keystore> --broadcast
 *      Reads the addresses from DEPLOYMENT_FILE, or app/src/config/deployments/<chainId>.json.
 */
contract SeedTrades is Script, TestnetPrices {
    /*//////////////////////////////////////////////////////////////
                              CONSTANTS
    //////////////////////////////////////////////////////////////*/

    uint16 internal constant SEED_LEVERAGE = 5;

    /// @dev Covers the open spread (5 bps base plus the OI term) and a Chainlink move between read and landing
    uint16 internal constant SEED_SLIPPAGE_BPS = 100;

    /*//////////////////////////////////////////////////////////////
                                TYPES
    //////////////////////////////////////////////////////////////*/

    /// @notice The contracts the seed trades touch
    struct Target {
        TradingEngine engine;
        TradingStorage tradingStorage;
        PythChainlinkOracle oracle;
        DemoPyth pyth;
        TestnetFaucet faucet;
    }

    /// @notice One seed trade
    struct SeedTrade {
        uint16 pairIndex;
        bool isLong;
        uint64 collateral; // USDC, 6 decimals
    }

    /*//////////////////////////////////////////////////////////////
                                  RUN
    //////////////////////////////////////////////////////////////*/

    function run() external {
        string memory defaultPath = string.concat("app/src/config/deployments/", vm.toString(block.chainid), ".json");
        string memory json = vm.readFile(vm.envOr("DEPLOYMENT_FILE", defaultPath));
        seed(
            Target({
                engine: TradingEngine(payable(vm.parseJsonAddress(json, ".engine"))),
                tradingStorage: TradingStorage(vm.parseJsonAddress(json, ".tradingStorage")),
                oracle: PythChainlinkOracle(vm.parseJsonAddress(json, ".oracle")),
                pyth: DemoPyth(vm.parseJsonAddress(json, ".pyth")),
                faucet: TestnetFaucet(vm.parseJsonAddress(json, ".faucet"))
            })
        );
    }

    /**
     * @notice Opens every seed trade the deployer does not hold yet, broadcasting from the faucet owner
     */
    function seed(Target memory _t) public {
        SeedTrade[4] memory trades = seedTrades();

        vm.startBroadcast();
        (, address deployer,) = vm.readCallers();

        for (uint256 i; i < trades.length; ++i) {
            SeedTrade memory s = trades[i];
            if (_holds(_t.tradingStorage, deployer, s.pairIndex, s.isLong)) continue;

            _t.faucet.mint(deployer, s.collateral);
            _t.faucet.USDC().approve(address(_t.engine), s.collateral);

            // Built the way the app builds every trade: one entry for the pair, priced at the Chainlink answer
            bytes[] memory update = new bytes[](1);
            update[0] = _mirrorPair(_t.oracle, _t.pyth, s.pairIndex);
            uint128 expectedPrice = _anchorPrice18(_t.oracle, s.pairIndex);
            _t.engine.openTrade{value: _t.pyth.getUpdateFee(update)}(
                s.pairIndex, s.isLong, s.collateral, SEED_LEVERAGE, expectedPrice, SEED_SLIPPAGE_BPS, 0, 0, update
            );
        }

        vm.stopBroadcast();
    }

    /**
     * @notice The seed trades: 200k long against 100k short on BTC/USD, 50k long against 150k short on ETH/USD
     */
    function seedTrades() public pure returns (SeedTrade[4] memory trades) {
        trades[0] = SeedTrade({pairIndex: 0, isLong: true, collateral: 40_000e6});
        trades[1] = SeedTrade({pairIndex: 0, isLong: false, collateral: 20_000e6});
        trades[2] = SeedTrade({pairIndex: 1, isLong: true, collateral: 10_000e6});
        trades[3] = SeedTrade({pairIndex: 1, isLong: false, collateral: 30_000e6});
    }

    /*//////////////////////////////////////////////////////////////
                          INTERNAL HELPERS
    //////////////////////////////////////////////////////////////*/

    /**
     * @dev Whether an account holds an open trade on a pair and side
     */
    function _holds(TradingStorage _storage, address _account, uint16 _pairIndex, bool _isLong) internal view returns (bool) {
        uint256[] memory ids = _storage.getUserTrades(_account);
        for (uint256 i; i < ids.length; ++i) {
            TradingStorage.Trade memory trade = _storage.getTrade(ids[i]);
            if (trade.pairIndex == _pairIndex && trade.isLong == _isLong) return true;
        }
        return false;
    }
}
