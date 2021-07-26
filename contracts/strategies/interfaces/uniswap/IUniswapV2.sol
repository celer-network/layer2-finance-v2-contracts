// SPDX-License-Identifier: MIT

pragma solidity 0.8.6;

interface IUniswapV2 {
    function swapExactTokensForTokens(
        uint256,
        uint256,
        address[] calldata,
        address,
        uint256
    ) external;

    function swapExactTokensForETH(
        uint256 amountIn,
        uint256 amountOutMin,
        address[] calldata paths,
        address to,
        uint256 deadline
    ) external;
}
