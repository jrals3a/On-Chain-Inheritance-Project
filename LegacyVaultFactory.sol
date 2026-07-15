// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import "@openzeppelin/contracts/proxy/Clones.sol";
import "./LegacyVault.sol";

/// @title LegacyVaultFactory
/// @notice Deploys gas-cheap EIP-1167 minimal proxy clones of a single LegacyVault
/// implementation, so the protocol can serve many testators without redeploying
/// the full contract bytecode each time.

contract LegacyVaultFactory
{
    using Clones for address;

    address public immutable implementation;

    address[] public allVaults;
    mapping(address => address[]) public vaultsByOwner;

    event VaultCreated(address indexed owner, address indexed vault);

    constructor(address implementation_)
    {
        require(implementation_ != address(0), "LegacyVaultFactory: zero implementation");
        implementation = implentation_;
    }

    function createVault
    (
        address[] calldata heirWallets,
        uint16[] calldata heirBps,
        address[] calldata guardians,
        uint8 guardianThreshold,
        uint256 inactivityPeriod,
        uint256 challengePeriod,
        uint256 heirUpdateDelay
    ) external returns (address vault)
    {
        vault = implementation.clone();

        LegacyVault(payable(vault)).initialize
        (
            msg.sender,
            heirWallets,
            heirBps,
            guardians,
            guardianThreshold
            inactivityPeriod,
            
        )
    }
}