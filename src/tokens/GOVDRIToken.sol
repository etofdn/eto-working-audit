// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/*
 *  ██████╗  ██████╗ ██╗   ██╗██████╗ ██████╗ ██╗    ████████╗ ██████╗ ██╗  ██╗███████╗███╗   ██╗
 * ██╔════╝ ██╔═══██╗██║   ██║██╔══██╗██╔══██╗██║    ╚══██╔══╝██╔═══██╗██║ ██╔╝██╔════╝████╗  ██║
 * ██║  ███╗██║   ██║██║   ██║██║  ██║██████╔╝██║       ██║   ██║   ██║█████╔╝ █████╗  ██╔██╗ ██║
 * ██║   ██║██║   ██║╚██╗ ██╔╝██║  ██║██╔══██╗██║       ██║   ██║   ██║██╔═██╗ ██╔══╝  ██║╚██╗██║
 * ╚██████╔╝╚██████╔╝ ╚████╔╝ ██████╔╝██║  ██║██║       ██║   ╚██████╔╝██║  ██╗███████╗██║ ╚████║
 *  ╚═════╝  ╚═════╝   ╚═══╝  ╚═════╝ ╚═╝  ╚═╝╚═╝       ╚═╝    ╚═════╝ ╚═╝  ╚═╝╚══════╝╚═╝  ╚═══╝
 *
 * GOVDRI Token - Governance Token
 *
 * Fixed-supply governance token for the DRI protocol with controlled minting and
 * transfer restrictions during bootstrap phase. Max supply: 1,000,000 tokens.
 */

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

contract GOVDRIToken is ERC20, Ownable {
    uint256 public constant MAX_SUPPLY = 1_000_000e18; // 1M tokens fixed supply
    bool public transfersDisabled = true;
    bool public mintingFinalized = false;

    mapping(address => bool) public authorizedMinters;

    event TransfersDisabled();
    event MintingFinalized();
    event AuthorizedMinterAdded(address indexed minter);
    event AuthorizedMinterRemoved(address indexed minter);

    modifier onlyAuthorizedMinter() {
        require(authorizedMinters[msg.sender] || msg.sender == owner(), "Not authorized minter");
        _;
    }

    modifier whenTransfersEnabled() {
        require(!transfersDisabled, "Transfers are disabled");
        _;
    }

    modifier beforeMintingFinalized() {
        require(!mintingFinalized, "Minting has been finalized");
        _;
    }

    constructor(address _owner) ERC20("GOV-DRI", "GOV-DRI") Ownable(_owner) {
        // Mint initial supply to multisig at deployment
        _mint(_owner, MAX_SUPPLY);
        mintingFinalized = true;
        emit MintingFinalized();
    }

    // Override all transfer functions to prevent transfers
    function transfer(address, uint256) public pure override returns (bool) {
        revert("Transfers disabled");
    }

    function transferFrom(address, address, uint256) public pure override returns (bool) {
        revert("Transfers disabled");
    }

    function approve(address, uint256) public pure override returns (bool) {
        revert("Approvals disabled");
    }

    function increaseAllowance(address, uint256) public pure returns (bool) {
        revert("Approvals disabled");
    }

    function decreaseAllowance(address, uint256) public pure returns (bool) {
        revert("Approvals disabled");
    }

    // Override delegate functions from potential extensions
    function delegate(address) external pure {
        revert("Delegation disabled");
    }

    function delegateBySig(address, uint256, uint256, uint8, bytes32, bytes32) external pure {
        revert("Delegation disabled");
    }

    // Custom mint function that respects the max supply
    function mint(address to, uint256 amount) external onlyOwner {
        require(!mintingFinalized, "Minting finalized");
        require(totalSupply() + amount <= MAX_SUPPLY, "Exceeds max supply");
        _mint(to, amount);
    }

    // Emergency function to enable transfers (should never be used in normal operation)
    function emergencyEnableTransfers() external onlyOwner {
        transfersDisabled = false;
    }

    // Key rotation functionality for multisig replacement
    function replaceSigner(address oldSigner, address newSigner, uint256 amount) external onlyOwner {
        require(balanceOf(oldSigner) >= amount, "Insufficient balance");
        require(newSigner != address(0), "Invalid new signer");

        // This is the only allowed "transfer" for key rotation
        _update(oldSigner, newSigner, amount);
    }

    // Voting power is simply the balance (non-transferable)
    function getVotingPower(address account) external view returns (uint256) {
        return balanceOf(account);
    }

    // Check if account has minimum voting power for proposals
    function canPropose(address account) external view returns (bool) {
        return balanceOf(account) >= 1e18; // 1 GOV-DRI minimum
    }
}
