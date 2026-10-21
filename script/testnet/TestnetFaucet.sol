// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {ERC20} from "solady/tokens/ERC20.sol";
import {Ownable} from "solady/auth/Ownable.sol";

/**
 * @title TestnetUSDC
 * @author GushALKDev
 * @notice Testnet-only stand-in for USDC (6 decimals), mintable only by the faucet that deploys it. It has no value
 * @dev Unlike Solady's default, Permit2 gets no implicit infinite allowance, so allowances behave as with USDC.
 */
contract TestnetUSDC is ERC20 {
    /*//////////////////////////////////////////////////////////////
                                STORAGE
    //////////////////////////////////////////////////////////////*/

    /// @notice The faucet, the only account that can mint
    address public immutable MINTER;

    /*//////////////////////////////////////////////////////////////
                                ERRORS
    //////////////////////////////////////////////////////////////*/

    error OnlyMinter(address caller);

    /*//////////////////////////////////////////////////////////////
                              CONSTRUCTOR
    //////////////////////////////////////////////////////////////*/

    constructor() {
        MINTER = msg.sender;
    }

    /*//////////////////////////////////////////////////////////////
                            ERC20 METADATA
    //////////////////////////////////////////////////////////////*/

    function name() public pure override returns (string memory) {
        return "Testnet USD Coin";
    }

    function symbol() public pure override returns (string memory) {
        return "USDC";
    }

    function decimals() public pure override returns (uint8) {
        return 6;
    }

    /*//////////////////////////////////////////////////////////////
                                MINTING
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Mints new tokens. Faucet only
     */
    function mint(address _to, uint256 _amount) external {
        if (msg.sender != MINTER) revert OnlyMinter(msg.sender);
        _mint(_to, _amount);
    }

    /*//////////////////////////////////////////////////////////////
                          INTERNAL OVERRIDES
    //////////////////////////////////////////////////////////////*/

    function _givePermit2InfiniteAllowance() internal pure override returns (bool) {
        return false;
    }
}

/**
 * @title TestnetFaucet
 * @author GushALKDev
 * @notice Testnet only. Deploys the demo's USDC stand-in and hands out USDC_DRIP of it once a day per address
 * @dev The daily limit slows how fast one address piles up tokens; it is per address, so it does not stop someone
 *      using many. The owner (the deployer) can mint any amount, which the testnet scripts use to seed the Vault
 *      and the seed trades. The faucet also ends up holding the seed Vault shares, and it has no function that
 *      could move them, so that liquidity stays in the Vault.
 */
contract TestnetFaucet is Ownable {
    /*//////////////////////////////////////////////////////////////
                              CONSTANTS
    //////////////////////////////////////////////////////////////*/

    /// @notice Minimum time between two claims from the same address
    uint256 public constant COOLDOWN = 1 days;

    /// @notice USDC handed out per claim (6 decimals)
    uint256 public constant USDC_DRIP = 10_000e6;

    /*//////////////////////////////////////////////////////////////
                                STORAGE
    //////////////////////////////////////////////////////////////*/

    TestnetUSDC public immutable USDC;

    /// @notice Timestamp of each address's last claim
    mapping(address account => uint256 timestamp) public lastClaim;

    /*//////////////////////////////////////////////////////////////
                                EVENTS
    //////////////////////////////////////////////////////////////*/

    event Claimed(address indexed account, uint256 amount);

    /*//////////////////////////////////////////////////////////////
                                ERRORS
    //////////////////////////////////////////////////////////////*/

    error ClaimTooSoon(address account, uint256 nextClaimAt);

    /*//////////////////////////////////////////////////////////////
                              CONSTRUCTOR
    //////////////////////////////////////////////////////////////*/

    constructor(address _owner) {
        _initializeOwner(_owner);
        USDC = new TestnetUSDC();
    }

    /*//////////////////////////////////////////////////////////////
                            CORE FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Sends USDC_DRIP to the caller, at most once per COOLDOWN
     */
    function claim() external {
        uint256 next = nextClaimAt(msg.sender);
        if (block.timestamp < next) revert ClaimTooSoon(msg.sender, next);
        lastClaim[msg.sender] = block.timestamp;

        USDC.mint(msg.sender, USDC_DRIP);
        emit Claimed(msg.sender, USDC_DRIP);
    }

    /**
     * @notice Mints any amount of USDC. Owner only, used to seed the demo
     */
    function mint(address _to, uint256 _amount) external onlyOwner {
        USDC.mint(_to, _amount);
    }

    /*//////////////////////////////////////////////////////////////
                            VIEW FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Earliest timestamp at which an address can claim again (0 if it never claimed)
     */
    function nextClaimAt(address _account) public view returns (uint256) {
        uint256 last = lastClaim[_account];
        return last == 0 ? 0 : last + COOLDOWN;
    }
}
