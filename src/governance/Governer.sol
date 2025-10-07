// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/*
 *  ██████╗  ██████╗ ██╗   ██╗███████╗██████╗ ███╗   ██╗ ██████╗ ██████╗
 * ██╔════╝ ██╔═══██╗██║   ██║██╔════╝██╔══██╗████╗  ██║██╔═══██╗██╔══██╗
 * ██║  ███╗██║   ██║██║   ██║█████╗  ██████╔╝██╔██╗ ██║██║   ██║██████╔╝
 * ██║   ██║██║   ██║╚██╗ ██╔╝██╔══╝  ██╔══██╗██║╚██╗██║██║   ██║██╔══██╗
 * ╚██████╔╝╚██████╔╝ ╚████╔╝ ███████╗██║  ██║██║ ╚████║╚██████╔╝██║  ██║
 *  ╚═════╝  ╚═════╝   ╚═══╝  ╚══════╝╚═╝  ╚═╝╚═╝  ╚═══╝ ╚═════╝ ╚═╝  ╚═╝
 *
 * Governor - On-Chain Governance System
 *
 * Token-weighted governance system for protocol parameter updates with timelock and
 * proposal lifecycle management. Supports executable proposals with risk documentation.
 */

import "../tokens/GOVDRIToken.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

contract Governor is Ownable, ReentrancyGuard {
    GOVDRIToken public immutable govToken;

    struct Proposal {
        uint256 id;
        address proposer;
        address target;
        string description;
        string riskMemoCID; // IPFS CID
        // Optional: full function signature for strict validation (e.g., "transfer(address,uint256)")
        string functionSignature;
        bytes calldata_;
        uint256 startTime;
        uint256 endTime;
        uint256 forVotes;
        uint256 againstVotes;
        uint256 abstainVotes;
        bool executed;
        bool cancelled;
        ProposalState state;
        mapping(address => bool) hasVoted;
        mapping(address => VoteType) votes;
    }

    enum ProposalState {
        Pending,
        Active,
        Cancelled,
        Defeated,
        Succeeded,
        Queued,
        Expired,
        Executed
    }

    enum VoteType {
        Against,
        For,
        Abstain
    }

    struct GovernanceConfig {
        uint256 votingPeriod; // 3 days in blocks
        uint256 quorum; // 600,000 GOV (60%)
        uint256 approvalThreshold; // 67% (2/3)
        uint256 proposalCooldown; // 24 hours
        uint256 timelockDelay; // 48 hours
        uint256 gracePeriod; // 7 days
    }

    GovernanceConfig public config;

    uint256 public proposalCount;
    mapping(uint256 => Proposal) public proposals;
    mapping(address => uint256) public lastProposalTime;

    // Timelock queue
    mapping(bytes32 => uint256) public queuedProposals;

    event ProposalCreated(
        uint256 indexed proposalId,
        address indexed proposer,
        string description,
        string riskMemoCID,
        uint256 startTime,
        uint256 endTime
    );

    event VoteCast(uint256 indexed proposalId, address indexed voter, VoteType voteType, uint256 weight, string reason);

    event ProposalQueued(uint256 indexed proposalId, uint256 executeTime);
    event ProposalExecuted(uint256 indexed proposalId);
    event ProposalCancelled(uint256 indexed proposalId);

    modifier onlyValidProposal(uint256 proposalId) {
        require(proposalId > 0 && proposalId <= proposalCount, "Invalid proposal");
        _;
    }

    modifier onlyProposer(uint256 proposalId) {
        require(proposals[proposalId].proposer == msg.sender, "Not proposer");
        _;
    }

    constructor(address _govToken, address _owner) Ownable(_owner) {
        require(_govToken != address(0), "Invalid gov token");
        govToken = GOVDRIToken(_govToken);

        // Default governance configuration (50% quorum and approval)
        config = GovernanceConfig({
            votingPeriod: 17280, // ~3 days (assuming 15s blocks)
            quorum: 500_000e18, // 500k tokens (50% of 1M)
            approvalThreshold: 5000, // 50% (in basis points)
            proposalCooldown: 5760, // ~24 hours
            timelockDelay: 11520, // ~48 hours
            gracePeriod: 40320 // ~7 days
        });
    }

    function propose(address target, string calldata description, string calldata riskMemoCID, bytes calldata calldata_)
        external
        nonReentrant
        returns (uint256)
    {
        require(govToken.canPropose(msg.sender), "Insufficient voting power");
        require(block.number >= lastProposalTime[msg.sender] + config.proposalCooldown, "Proposal cooldown active");
        require(target != address(0), "Invalid target");
        require(bytes(description).length > 0, "Empty description");
        require(bytes(riskMemoCID).length > 0, "Empty risk memo CID");
        require(calldata_.length > 0, "Empty calldata");

        proposalCount++;
        uint256 proposalId = proposalCount;

        Proposal storage proposal = proposals[proposalId];
        proposal.id = proposalId;
        proposal.proposer = msg.sender;
        proposal.target = target;
        proposal.description = description;
        proposal.riskMemoCID = riskMemoCID;
        // For backward compatibility, proposals created via propose() have no functionSignature
        proposal.functionSignature = "";
        proposal.calldata_ = calldata_;
        proposal.startTime = block.number;
        proposal.endTime = block.number + config.votingPeriod;
        proposal.state = ProposalState.Active;

        lastProposalTime[msg.sender] = block.number;

        emit ProposalCreated(proposalId, msg.sender, description, riskMemoCID, proposal.startTime, proposal.endTime);

        return proposalId;
    }

    // Strict variant that records the explicit function signature for validation during execution
    function proposeAdvanced(
        address target,
        string calldata description,
        string calldata riskMemoCID,
        string calldata functionSignature,
        bytes calldata calldata_
    ) external nonReentrant returns (uint256) {
        require(govToken.canPropose(msg.sender), "Insufficient voting power");
        require(block.number >= lastProposalTime[msg.sender] + config.proposalCooldown, "Proposal cooldown active");
        require(target != address(0), "Invalid target");
        require(bytes(description).length > 0, "Empty description");
        require(bytes(riskMemoCID).length > 0, "Empty risk memo CID");
        require(bytes(functionSignature).length > 0, "Empty function signature");
        require(calldata_.length > 0, "Empty calldata");

        proposalCount++;
        uint256 proposalId = proposalCount;

        Proposal storage proposal = proposals[proposalId];
        proposal.id = proposalId;
        proposal.proposer = msg.sender;
        proposal.target = target;
        proposal.description = description;
        proposal.riskMemoCID = riskMemoCID;
        proposal.functionSignature = functionSignature;
        proposal.calldata_ = calldata_;
        proposal.startTime = block.number;
        proposal.endTime = block.number + config.votingPeriod;
        proposal.state = ProposalState.Active;

        lastProposalTime[msg.sender] = block.number;

        emit ProposalCreated(proposalId, msg.sender, description, riskMemoCID, proposal.startTime, proposal.endTime);
        return proposalId;
    }

    function castVote(uint256 proposalId, VoteType voteType, string calldata reason)
        external
        onlyValidProposal(proposalId)
        nonReentrant
    {
        Proposal storage proposal = proposals[proposalId];
        require(proposal.state == ProposalState.Active, "Proposal not active");
        require(block.number <= proposal.endTime, "Voting period ended");
        require(!proposal.hasVoted[msg.sender], "Already voted");

        uint256 weight = govToken.getVotingPower(msg.sender);
        require(weight > 0, "No voting power");

        proposal.hasVoted[msg.sender] = true;
        proposal.votes[msg.sender] = voteType;

        if (voteType == VoteType.For) {
            proposal.forVotes += weight;
        } else if (voteType == VoteType.Against) {
            proposal.againstVotes += weight;
        } else {
            proposal.abstainVotes += weight;
        }

        emit VoteCast(proposalId, msg.sender, voteType, weight, reason);

        // Update proposal state if voting ended
        if (block.number >= proposal.endTime) {
            _updateProposalState(proposalId);
        }
    }

    function queue(uint256 proposalId) external onlyValidProposal(proposalId) {
        Proposal storage proposal = proposals[proposalId];
        require(proposal.state == ProposalState.Succeeded, "Proposal not succeeded");

        bytes32 proposalHash = keccak256(abi.encode(proposalId, proposal.calldata_));
        uint256 executeTime = block.timestamp + config.timelockDelay;

        queuedProposals[proposalHash] = executeTime;
        proposal.state = ProposalState.Queued;

        emit ProposalQueued(proposalId, executeTime);
    }

    // SECURITY FIX: Execution guards and limits
    mapping(address => bool) public whitelistedTargets;
    mapping(bytes4 => bool) public whitelistedFunctions; // selector-level (legacy)
    mapping(bytes32 => bool) public whitelistedFunctionSignatures; // keccak256("transfer(address,uint256)")
    mapping(address => bool) public whitelistedRecipients; // optional allowlist for token transfers
    uint256 public maxValueTransfer = 100000e6; // Max 100k USDC per proposal

    function execute(uint256 proposalId) external onlyValidProposal(proposalId) nonReentrant {
        Proposal storage proposal = proposals[proposalId];
        require(proposal.state == ProposalState.Queued, "Proposal not queued");

        bytes32 proposalHash = keccak256(abi.encode(proposalId, proposal.calldata_));
        uint256 executeTime = queuedProposals[proposalHash];

        require(executeTime > 0, "Proposal not in timelock");
        require(block.timestamp >= executeTime, "Timelock not expired");
        require(block.timestamp <= executeTime + config.gracePeriod, "Grace period expired");

        // Validate target and function
        require(whitelistedTargets[proposal.target], "Target not whitelisted");
        // Require explicit function signature for all proposals
        require(bytes(proposal.functionSignature).length > 0, "Function signature required");

        // Derive selector from signature and enforce exact match with calldata
        bytes4 selector = bytes4(proposal.calldata_);
        bytes4 expectedSelector = bytes4(keccak256(bytes(proposal.functionSignature)));
        require(selector == expectedSelector, "Selector mismatch");

        // Enforce both selector and full signature allowlists
        require(whitelistedFunctions[selector], "Function selector not whitelisted");
        bytes32 sigHash = keccak256(bytes(proposal.functionSignature));
        require(whitelistedFunctionSignatures[sigHash], "Function signature not whitelisted");

        // Parameter-level validation for known signatures
        if (sigHash == keccak256("transfer(address,uint256)")) {
            // Enforce exact calldata size: 4-byte selector + 32 + 32 = 68
            require(proposal.calldata_.length == 4 + 32 + 32, "Invalid calldata length for transfer");
            // Decode directly from the calldata slice after the selector
            bytes memory calldataSlice = new bytes(proposal.calldata_.length - 4);
            for (uint256 i = 4; i < proposal.calldata_.length; i++) {
                calldataSlice[i - 4] = proposal.calldata_[i];
            }
            (address recipient, uint256 amount) = abi.decode(calldataSlice, (address, uint256));
            require(whitelistedRecipients[recipient], "Recipient not whitelisted");
            require(amount <= maxValueTransfer, "Transfer exceeds limit");
        }

        // SECURITY FIX: Check for value transfer limits
        if (selector == 0xa9059cbb) { // transfer(address,uint256)
            bytes memory calldataSlice = new bytes(proposal.calldata_.length - 4);
            for (uint256 i = 4; i < proposal.calldata_.length; i++) {
                calldataSlice[i-4] = proposal.calldata_[i];
            }
            (, uint256 amount) = abi.decode(calldataSlice, (address, uint256));
            require(amount <= maxValueTransfer, "Transfer exceeds limit");
        }

        // Mark executed first for reentrancy safety
        proposal.state = ProposalState.Executed;
        proposal.executed = true;
        delete queuedProposals[proposalHash];

        // Execute the actual call
        (bool success, bytes memory returnData) = proposal.target.call(proposal.calldata_);
        require(success, string(abi.encodePacked("Execution failed: ", returnData)));

        emit ProposalExecuted(proposalId);
    }

    function cancel(uint256 proposalId) external {
        Proposal storage proposal = proposals[proposalId];
        require(msg.sender == proposal.proposer || msg.sender == owner(), "Not authorized to cancel");
        require(
            proposal.state == ProposalState.Active || proposal.state == ProposalState.Pending
                || proposal.state == ProposalState.Queued,
            "Cannot cancel"
        );

        proposal.state = ProposalState.Cancelled;
        proposal.cancelled = true;

        emit ProposalCancelled(proposalId);
    }

    function getProposalState(uint256 proposalId) external view returns (ProposalState) {
        require(proposalId > 0 && proposalId <= proposalCount, "Invalid proposal");
        return proposals[proposalId].state;
    }

    // SECURITY FIX: Management functions for execution guards
    function addWhitelistedTarget(address target) external onlyOwner {
        whitelistedTargets[target] = true;
    }

    function removeWhitelistedTarget(address target) external onlyOwner {
        whitelistedTargets[target] = false;
    }

    function addWhitelistedFunction(bytes4 selector) external onlyOwner {
        whitelistedFunctions[selector] = true;
    }

    function removeWhitelistedFunction(bytes4 selector) external onlyOwner {
        whitelistedFunctions[selector] = false;
    }

    // Manage full function signature allowlist (e.g., "transfer(address,uint256)")
    function addWhitelistedFunctionSignature(string calldata signature) external onlyOwner {
        bytes32 sigHash = keccak256(bytes(signature));
        whitelistedFunctionSignatures[sigHash] = true;
    }

    function removeWhitelistedFunctionSignature(string calldata signature) external onlyOwner {
        bytes32 sigHash = keccak256(bytes(signature));
        whitelistedFunctionSignatures[sigHash] = false;
    }

    // Manage transfer recipient allowlist for parameter-level guards
    function addWhitelistedRecipient(address recipient) external onlyOwner {
        whitelistedRecipients[recipient] = true;
    }

    function removeWhitelistedRecipient(address recipient) external onlyOwner {
        whitelistedRecipients[recipient] = false;
    }

    function setMaxValueTransfer(uint256 newLimit) external onlyOwner {
        maxValueTransfer = newLimit;
    }

    function getProposalVotes(uint256 proposalId)
        external
        view
        returns (uint256 forVotes, uint256 againstVotes, uint256 abstainVotes)
    {
        Proposal storage proposal = proposals[proposalId];
        return (proposal.forVotes, proposal.againstVotes, proposal.abstainVotes);
    }

    function hasVoted(uint256 proposalId, address account) external view returns (bool) {
        return proposals[proposalId].hasVoted[account];
    }

    function getVote(uint256 proposalId, address account) external view returns (VoteType) {
        return proposals[proposalId].votes[account];
    }

    function updateGovernanceConfig(GovernanceConfig calldata _config) external onlyOwner {
        require(_config.quorum >= 500_000e18, "Quorum too low"); // Min 50%
        require(_config.approvalThreshold >= 5000 && _config.approvalThreshold <= 8000, "Invalid threshold"); // 50-80%
        require(_config.votingPeriod >= 5760 && _config.votingPeriod <= 40320, "Invalid voting period"); // 1-7 days
        require(_config.timelockDelay >= 5760 && _config.timelockDelay <= 241920, "Invalid timelock"); // 1-168 hours

        config = _config;
    }

    function _updateProposalState(uint256 proposalId) internal {
        Proposal storage proposal = proposals[proposalId];

        if (proposal.cancelled) {
            proposal.state = ProposalState.Cancelled;
            return;
        }

        if (proposal.executed) {
            proposal.state = ProposalState.Executed;
            return;
        }

        if (block.number <= proposal.endTime) {
            proposal.state = ProposalState.Active;
            return;
        }

        // Total votes including abstain for quorum check
        uint256 totalVotes = proposal.forVotes + proposal.againstVotes + proposal.abstainVotes;

        // Check quorum (participation)
        if (totalVotes < config.quorum) {
            proposal.state = ProposalState.Defeated;
            return;
        }

        // For approval, only count For vs Against (abstain doesn't count)
        uint256 totalDecisiveVotes = proposal.forVotes + proposal.againstVotes;
        if (totalDecisiveVotes == 0) {
            proposal.state = ProposalState.Defeated;
            return;
        }

        // Approval rate in basis points
        uint256 approvalRate = (proposal.forVotes * 10000) / totalDecisiveVotes;
        if (approvalRate >= config.approvalThreshold) {
            proposal.state = ProposalState.Succeeded;
        } else {
            proposal.state = ProposalState.Defeated;
        }
    }
}
