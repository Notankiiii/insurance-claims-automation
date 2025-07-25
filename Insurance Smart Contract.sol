
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

/**
 * @title Insurance Claims Automation
 * @dev Automated flight delay insurance with instant payouts
 * @author Insurance Claims Automation Team
 */

import "@chainlink/contracts/src/v0.8/interfaces/AggregatorV3Interface.sol";

contract InsuranceClaimsAutomation {
    
    // Events
    event PolicyCreated(uint256 indexed policyId, address indexed policyholder, string flightNumber);
    event PayoutTriggered(uint256 indexed policyId, uint256 payoutAmount, string reason);
    event FlightStatusUpdated(uint256 indexed policyId, uint8 status, uint256 delayMinutes);
    
    // Enums
    enum FlightStatus { OnTime, Delayed, Cancelled, Departed }
    enum PolicyStatus { Active, Claimed, Expired, Cancelled }
    
    // Structs
    struct FlightPolicy {
        uint256 policyId;
        address policyholder;
        string flightNumber;
        uint256 scheduledDeparture;
        uint256 premium;
        uint256 maxPayout;
        PolicyStatus status;
        FlightStatus flightStatus;
        uint256 actualDeparture;
        uint256 delayMinutes;
        bool payoutProcessed;
    }
    
    struct PayoutTier {
        uint256 minDelayMinutes;
        uint256 maxDelayMinutes;
        uint256 multiplier; // Multiplier in basis points (100 = 1x)
    }
    
    // State variables
    mapping(uint256 => FlightPolicy) public policies;
    mapping(string => uint256[]) public flightToPolicies;
    mapping(address => uint256[]) public userPolicies;
    
    PayoutTier[] public payoutTiers;
    
    uint256 public policyCounter;
    uint256 public totalPremiumsCollected;
    uint256 public totalPayoutsProcessed;
    address public owner;
    
    // Oracle interface for flight data
    AggregatorV3Interface internal flightDataFeed;
    
    // Modifiers
    modifier onlyOwner() {
        require(msg.sender == owner, "Only owner can call this function");
        _;
    }
    
    modifier validPolicy(uint256 _policyId) {
        require(_policyId > 0 && _policyId <= policyCounter, "Invalid policy ID");
        require(policies[_policyId].status == PolicyStatus.Active, "Policy not active");
        _;
    }
    
    constructor() {
        owner = msg.sender;
        
        // Initialize payout tiers
        payoutTiers.push(PayoutTier(120, 240, 200)); // 2-4 hours: 2x payout
        payoutTiers.push(PayoutTier(240, 480, 300)); // 4-8 hours: 3x payout  
        payoutTiers.push(PayoutTier(480, type(uint256).max, 500)); // 8+ hours: 5x payout
    }
    
    /**
     * @dev Core Function 1: Create Insurance Policy
     * @param _flightNumber Flight identifier (e.g., "AA123")
     * @param _scheduledDeparture Scheduled departure timestamp
     * @param _maxPayout Maximum payout amount for this policy
     */
    function createPolicy(
        string memory _flightNumber,
        uint256 _scheduledDeparture,
        uint256 _maxPayout
    ) external payable returns (uint256) {
        require(msg.value > 0, "Premium must be greater than 0");
        require(_scheduledDeparture > block.timestamp, "Flight must be in the future");
        require(_maxPayout >= msg.value * 2, "Max payout must be at least 2x premium");
        
        policyCounter++;
        
        FlightPolicy memory newPolicy = FlightPolicy({
            policyId: policyCounter,
            policyholder: msg.sender,
            flightNumber: _flightNumber,
            scheduledDeparture: _scheduledDeparture,
            premium: msg.value,
            maxPayout: _maxPayout,
            status: PolicyStatus.Active,
            flightStatus: FlightStatus.OnTime,
            actualDeparture: 0,
            delayMinutes: 0,
            payoutProcessed: false
        });
        
        policies[policyCounter] = newPolicy;
        flightToPolicies[_flightNumber].push(policyCounter);
        userPolicies[msg.sender].push(policyCounter);
        
        totalPremiumsCollected += msg.value;
        
        emit PolicyCreated(policyCounter, msg.sender, _flightNumber);
        
        return policyCounter;
    }
    
    /**
     * @dev Core Function 2: Update Flight Status and Process Claims
     * @param _policyId Policy identifier
     * @param _flightStatus Current flight status
     * @param _actualDeparture Actual departure timestamp (0 if not departed)
     */
    function updateFlightStatus(
        uint256 _policyId,
        FlightStatus _flightStatus,
        uint256 _actualDeparture
    ) external onlyOwner validPolicy(_policyId) {
        FlightPolicy storage policy = policies[_policyId];
        
        policy.flightStatus = _flightStatus;
        policy.actualDeparture = _actualDeparture;
        
        // Calculate delay if flight has departed or been cancelled
        if (_flightStatus == FlightStatus.Delayed || _flightStatus == FlightStatus.Cancelled) {
            if (_actualDeparture > 0 && _actualDeparture > policy.scheduledDeparture) {
                policy.delayMinutes = (_actualDeparture - policy.scheduledDeparture) / 60;
            } else if (_flightStatus == FlightStatus.Cancelled) {
                policy.delayMinutes = type(uint256).max; // Treat cancellation as max delay
            }
        }
        
        emit FlightStatusUpdated(_policyId, uint8(_flightStatus), policy.delayMinutes);
        
        // Automatically trigger payout if conditions are met
        if (policy.delayMinutes >= 120 && !policy.payoutProcessed) { // 2+ hours delay
            _processPayout(_policyId);
        }
    }
    
    /**
     * @dev Core Function 3: Process Automated Payout
     * @param _policyId Policy identifier for payout processing
     */
    function processPayout(uint256 _policyId) external validPolicy(_policyId) {
        FlightPolicy storage policy = policies[_policyId];
        
        require(
            msg.sender == policy.policyholder || msg.sender == owner,
            "Only policyholder or owner can trigger payout"
        );
        require(!policy.payoutProcessed, "Payout already processed");
        require(policy.delayMinutes >= 120, "Delay not sufficient for payout");
        
        _processPayout(_policyId);
    }
    
    /**
     * @dev Internal function to calculate and process payout
     * @param _policyId Policy identifier
     */
    function _processPayout(uint256 _policyId) internal {
        FlightPolicy storage policy = policies[_policyId];
        
        uint256 payoutAmount = _calculatePayout(policy.premium, policy.delayMinutes);
        
        // Cap payout at maxPayout amount
        if (payoutAmount > policy.maxPayout) {
            payoutAmount = policy.maxPayout;
        }
        
        // Ensure contract has sufficient balance
        require(address(this).balance >= payoutAmount, "Insufficient contract balance");
        
        policy.payoutProcessed = true;
        policy.status = PolicyStatus.Claimed;
        totalPayoutsProcessed += payoutAmount;
        
        // Transfer payout to policyholder
        (bool success, ) = payable(policy.policyholder).call{value: payoutAmount}("");
        require(success, "Payout transfer failed");
        
        string memory reason = policy.flightStatus == FlightStatus.Cancelled 
            ? "Flight Cancelled" 
            : "Flight Delayed";
            
        emit PayoutTriggered(_policyId, payoutAmount, reason);
    }
    
    /**
     * @dev Calculate payout amount based on delay duration
     * @param _premium Original premium paid
     * @param _delayMinutes Flight delay in minutes
     * @return Calculated payout amount
     */
    function _calculatePayout(uint256 _premium, uint256 _delayMinutes) internal view returns (uint256) {
        if (_delayMinutes < 120) return 0; // No payout for delays under 2 hours
        
        for (uint256 i = 0; i < payoutTiers.length; i++) {
            PayoutTier memory tier = payoutTiers[i];
            if (_delayMinutes >= tier.minDelayMinutes && _delayMinutes < tier.maxDelayMinutes) {
                return (_premium * tier.multiplier) / 100;
            }
        }
        
        // Default to highest tier if delay exceeds all defined ranges
        return (_premium * payoutTiers[payoutTiers.length - 1].multiplier) / 100;
    }
    
    // View functions
    function getPolicyDetails(uint256 _policyId) external view returns (FlightPolicy memory) {
        return policies[_policyId];
    }
    
    function getUserPolicies(address _user) external view returns (uint256[] memory) {
        return userPolicies[_user];
    }
    
    function getFlightPolicies(string memory _flightNumber) external view returns (uint256[] memory) {
        return flightToPolicies[_flightNumber];
    }
    
    function getContractBalance() external view returns (uint256) {
        return address(this).balance;
    }
    
    // Admin functions
    function addPayoutTier(uint256 _minDelay, uint256 _maxDelay, uint256 _multiplier) external onlyOwner {
        payoutTiers.push(PayoutTier(_minDelay, _maxDelay, _multiplier));
    }
    
    function withdrawExcessFunds(uint256 _amount) external onlyOwner {
        require(_amount <= address(this).balance, "Insufficient balance");
        payable(owner).transfer(_amount);
    }
    
    // Emergency functions
    function cancelPolicy(uint256 _policyId) external validPolicy(_policyId) {
        FlightPolicy storage policy = policies[_policyId];
        require(
            msg.sender == policy.policyholder || msg.sender == owner,
            "Only policyholder or owner can cancel"
        );
        require(block.timestamp < policy.scheduledDeparture, "Cannot cancel after scheduled departure");
        
        policy.status = PolicyStatus.Cancelled;
        
        // Refund 90% of premium (10% processing fee)
        uint256 refundAmount = (policy.premium * 90) / 100;
        payable(policy.policyholder).transfer(refundAmount);
    }
}
