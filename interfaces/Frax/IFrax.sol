// SPDX-License-Identifier: MIT
pragma solidity 0.6.12;

interface IFrax {
    // Returns X FRAX = 1 USD
    function frax_price() external view returns (uint256);

    // Returns X FXS = 1 USD
    function fxs_price() external view returns (uint256);

    function eth_usd_price() external view returns (uint256);
}
