// SPDX-License-Identifier: UNLICENSED

pragma solidity 0.6.11;

interface ICommunityIssuance { 
    
    // --- Events ---
    
    event VSTATokenAddressSet(address _vestaTokenAddress);
    event StabilityPoolAddressSet(address _stabilityPoolAddress);
    event TotalVSTAIssuedUpdated(uint _totalVSTAIssued);

    // --- Functions ---

    function setAddresses(address _vestaTokenAddress, address _stabilityPoolAddress) external;

    function issueVSTA() external returns (uint);

    function sendVSTA(address _account, uint _VSTAamount) external;
}
