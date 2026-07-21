// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Script} from "forge-std/Script.sol";
import {console} from "forge-std/console.sol";
import {TradingEngine} from "../src/TradingEngine.sol";
import {TradingStorage} from "../src/TradingStorage.sol";
import {Vault} from "../src/Vault.sol";
import {AssistantFund} from "../src/AssistantFund.sol";
import {SolvencyManager} from "../src/SolvencyManager.sol";
import {BondDepository} from "../src/BondDepository.sol";
import {SynthToken} from "../src/SynthToken.sol";
import {SpreadManager} from "../src/SpreadManager.sol";
import {PythChainlinkOracle} from "../src/PythChainlinkOracle.sol";

/**
 * @title DeployConfig
 * @notice Deployment parameters, kept separate so tests can deploy the exact production wiring.
 */
struct DeployConfig {
    address asset; // USDC (6 decimals)
    address pyth; // Pyth contract for the target chain
    address owner; // Protocol owner / admin
    address keeper; // SpreadManager volatility keeper
    uint256 assistantFundTargetCap; // Reserve cap; overflow is skimmed to the Vault
    uint256 bondDiscountBps; // Bond discount (<= MAX_DISCOUNT_BPS = 1000)
    uint256 baseSpreadBps;
    uint256 impactFactor;
    uint256 volFactor;
    uint256 maxSpreadBps;
    uint256 maxVolatilityChangeBps;
}

/**
 * @title Deployed
 * @notice Every contract making up a deployment, returned so callers can wire tests or verify.
 */
struct Deployed {
    Vault vault;
    TradingStorage tradingStorage;
    TradingEngine engine;
    SpreadManager spreadManager;
    PythChainlinkOracle oracle;
    AssistantFund assistantFund;
    SynthToken synth;
    BondDepository bondDepository;
    SolvencyManager solvencyManager;
}

/**
 * @title DeployLib
 * @author GushALKDev
 * @notice Deploys and wires the full protocol in one place, so the production topology has a single
 *         source of truth shared by the deploy script and the integration tests.
 * @dev Ordering matters: BondDepository needs the Vault and SynthToken, the SolvencyManager needs all
 *      three, and the wiring calls can only run once every address exists. TradingEngine's treasury is
 *      deliberately the AssistantFund, so the 20% protocol fee share funds the Layer 2 reserve.
 */
library DeployLib {
    function deploy(DeployConfig memory _cfg) internal returns (Deployed memory d) {
        // --- Core ---
        d.tradingStorage = new TradingStorage(_cfg.asset, _cfg.owner);
        d.vault = new Vault(_cfg.asset, _cfg.owner);
        d.oracle = new PythChainlinkOracle(_cfg.pyth, _cfg.owner);
        d.spreadManager = new SpreadManager(
            _cfg.baseSpreadBps,
            _cfg.impactFactor,
            _cfg.volFactor,
            _cfg.maxSpreadBps,
            _cfg.maxVolatilityChangeBps,
            _cfg.keeper,
            _cfg.owner
        );

        // --- Solvency layers ---
        d.assistantFund = new AssistantFund(_cfg.asset, address(d.vault), _cfg.assistantFundTargetCap, _cfg.owner);
        d.synth = new SynthToken(_cfg.owner);
        d.bondDepository =
            new BondDepository(_cfg.asset, address(d.vault), address(d.synth), _cfg.bondDiscountBps, _cfg.owner);

        // Treasury is the AssistantFund: the 20% fee share accumulates as the Layer 2 reserve
        d.engine = new TradingEngine(
            address(d.tradingStorage),
            address(d.vault),
            address(d.oracle),
            _cfg.asset,
            address(d.assistantFund),
            address(d.spreadManager),
            _cfg.owner
        );

        d.solvencyManager =
            new SolvencyManager(address(d.vault), address(d.assistantFund), address(d.bondDepository), _cfg.owner);

        return d;
    }

    /**
     * @notice Grant every cross-contract permission the protocol needs to operate
     * @dev Must be called by the owner. Without this the system is deployed but inert: the engine
     *      cannot touch storage or the Vault, bonding cannot mint, and solvency cannot recapitalize.
     */
    function wire(Deployed memory _d) internal {
        _d.tradingStorage.setTradingEngine(address(_d.engine));
        _d.vault.setTradingEngine(address(_d.engine));
        _d.synth.setMinter(address(_d.bondDepository));
        _d.assistantFund.setSolvencyManager(address(_d.solvencyManager));
        _d.bondDepository.setSolvencyManager(address(_d.solvencyManager));
    }
}

/**
 * @title Deploy
 * @author GushALKDev
 * @notice Deployment script for the full protocol.
 * @dev Reads configuration from the environment so the same script serves local Anvil and testnets:
 *
 *      ```bash
 *      forge script script/Deploy.s.sol --rpc-url <rpc> --broadcast
 *      ```
 *
 *      Required env vars: `PRIVATE_KEY`, `USDC_ADDRESS`, `PYTH_ADDRESS`.
 *      Optional: `OWNER_ADDRESS`, `KEEPER_ADDRESS` (both default to the deployer).
 *
 *      Pair feeds are NOT configured here: `oracle.setPairFeed` and `tradingStorage.addPair` need
 *      per-chain Pyth feed IDs and Chainlink aggregators, so they are left as explicit owner actions.
 */
contract Deploy is Script {
    function run() external returns (Deployed memory d) {
        uint256 pk = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(pk);

        DeployConfig memory cfg = DeployConfig({
            asset: vm.envAddress("USDC_ADDRESS"),
            pyth: vm.envAddress("PYTH_ADDRESS"),
            owner: vm.envOr("OWNER_ADDRESS", deployer),
            keeper: vm.envOr("KEEPER_ADDRESS", deployer),
            assistantFundTargetCap: 1_000_000 * 10 ** 6, // 1M USDC reserve cap
            bondDiscountBps: 500, // 5%
            baseSpreadBps: 5, // 0.05%
            impactFactor: 3e5, // ~3 bps at 10M OI
            volFactor: 100, // ~3 bps at 3% volatility
            maxSpreadBps: 100, // 1% ceiling
            maxVolatilityChangeBps: 5000 // 50% max change per keeper update
        });

        vm.startBroadcast(pk);
        d = DeployLib.deploy(cfg);
        // Wiring is owner-gated; it only succeeds here when the deployer is the owner
        if (cfg.owner == deployer) DeployLib.wire(d);
        vm.stopBroadcast();

        _log(d, cfg.owner == deployer);
        return d;
    }

    function _log(Deployed memory _d, bool _wired) internal pure {
        console.log("=== Deployed ===");
        console.log("Vault           :", address(_d.vault));
        console.log("TradingStorage  :", address(_d.tradingStorage));
        console.log("TradingEngine   :", address(_d.engine));
        console.log("SpreadManager   :", address(_d.spreadManager));
        console.log("Oracle          :", address(_d.oracle));
        console.log("AssistantFund   :", address(_d.assistantFund));
        console.log("SynthToken      :", address(_d.synth));
        console.log("BondDepository  :", address(_d.bondDepository));
        console.log("SolvencyManager :", address(_d.solvencyManager));
        if (_wired) {
            console.log("");
            console.log("Wired. Remaining owner actions: oracle.setPairFeed + tradingStorage.addPair");
        } else {
            console.log("");
            console.log("NOT wired: owner != deployer. Owner must call DeployLib.wire equivalents.");
        }
    }
}
