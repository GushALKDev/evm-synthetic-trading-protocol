// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {ERC20} from "solady/tokens/ERC20.sol";
import {Ownable} from "solady/auth/Ownable.sol";

/**
 * @title SynthToken
 * @author GushALKDev
 * @notice Governance token ($SYNTH) of the protocol. Used as the incentive asset sold by the
 *         BondDepository (Layer 3 solvency) in exchange for USDC injected into the Vault.
 * @dev Minting is restricted to a single authorized minter (the BondDepository), settable by the
 *      owner. Burning is permissionless over one's own balance (or via allowance) so the protocol
 *      can execute buybacks and holders can exit; the supply is only ever inflated by bonding.
 */
contract SynthToken is ERC20, Ownable {
    /*//////////////////////////////////////////////////////////////
                                STORAGE
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice The only address allowed to mint new tokens (the BondDepository)
     */
    address public minter;

    /*//////////////////////////////////////////////////////////////
                                EVENTS
    //////////////////////////////////////////////////////////////*/

    event MinterUpdated(address indexed newMinter);

    /*//////////////////////////////////////////////////////////////
                                ERRORS
    //////////////////////////////////////////////////////////////*/

    error ZeroAddress();
    error CallerNotMinter();
    error MinterNotSet();

    /*//////////////////////////////////////////////////////////////
                              MODIFIERS
    //////////////////////////////////////////////////////////////*/

    modifier onlyMinter() {
        _requireMinter();
        _;
    }

    /*//////////////////////////////////////////////////////////////
                          INTERNAL HELPERS
    //////////////////////////////////////////////////////////////*/

    function _requireMinter() internal view {
        if (minter == address(0)) revert MinterNotSet();
        if (msg.sender != minter) revert CallerNotMinter();
    }

    /*//////////////////////////////////////////////////////////////
                              CONSTRUCTOR
    //////////////////////////////////////////////////////////////*/

    constructor(address _owner) {
        if (_owner == address(0)) revert ZeroAddress();
        _initializeOwner(_owner);
    }

    /*//////////////////////////////////////////////////////////////
                            ERC20 METADATA
    //////////////////////////////////////////////////////////////*/

    function name() public pure override returns (string memory) {
        return "Synth Token";
    }

    function symbol() public pure override returns (string memory) {
        return "SYNTH";
    }

    /*//////////////////////////////////////////////////////////////
                            CORE FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Mint new tokens to a recipient
     * @dev Only the minter (BondDepository) may call. Reverts if the minter is unset.
     * @param _to Recipient of the newly minted tokens
     * @param _amount Amount to mint (18 decimals)
     */
    function mint(address _to, uint256 _amount) external onlyMinter {
        _mint(_to, _amount);
    }

    /**
     * @notice Burn tokens from the caller's balance
     * @param _amount Amount to burn (18 decimals)
     */
    function burn(uint256 _amount) external {
        _burn(msg.sender, _amount);
    }

    /**
     * @notice Burn tokens from another account using the caller's allowance
     * @dev Used for protocol buybacks where the burner spends an approved balance.
     * @param _from Account to burn from
     * @param _amount Amount to burn (18 decimals)
     */
    function burnFrom(address _from, uint256 _amount) external {
        _spendAllowance(_from, msg.sender, _amount);
        _burn(_from, _amount);
    }

    /*//////////////////////////////////////////////////////////////
                            ADMIN FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Set the authorized minter (the BondDepository)
     * @param _minter The minter address
     */
    function setMinter(address _minter) external onlyOwner {
        if (_minter == address(0)) revert ZeroAddress();
        minter = _minter;
        emit MinterUpdated(_minter);
    }
}
