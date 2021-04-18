// SPDX-License-Identifier: AGPL-3.0

pragma solidity 0.6.12;

interface IUniswapOracle {
    function update() external;

    function PERIOD() external pure returns (uint256);

    function blockTimestampLast() external pure returns (uint32);
}
