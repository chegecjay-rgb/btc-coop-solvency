// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";

interface IProtocolSafetyRegistry is IERC165 {
    function protocolCount() external view returns (uint256);

    function protocolIdAt(uint256 index) external view returns (bytes32);

    function moduleOf(bytes32 protocolId) external view returns (address);

    function isRegisteredModule(address module) external view returns (bool);
}
