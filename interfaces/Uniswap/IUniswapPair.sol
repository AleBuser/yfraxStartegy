// SPDX-License-Identifier: AGPL-3.0

pragma solidity 0.6.12;

interface IUniswapPair {
    function getReserves()
        external
        view
        returns (
            uint112,
            uint112,
            uint32
        );

    function totalSupply() external view returns (uint256);

    function approve(address, uint256) external returns (bool);

    function balanceOf(address) external returns (uint256);
}
