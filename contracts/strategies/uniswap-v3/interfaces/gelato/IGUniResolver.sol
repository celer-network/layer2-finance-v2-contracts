// SPDX-License-Identifier: GPL-3.0-or-later

pragma solidity 0.8.6;

import {IGUniPool} from "./IGUniPool.sol";

interface IGUniResolver {
    function getUnderlyingBalances(IGUniPool pool, uint256 balance)
        external
        view
        returns (uint256 amount0, uint256 amount1);

    function getPoolUnderlyingBalances(IGUniPool pool) external view returns (uint256 amount0, uint256 amount1);

    function getRebalanceParams(
        IGUniPool pool,
        uint256 amount0In,
        uint256 amount1In,
        uint16 slippage
    )
        external
        view
        returns (
            bool zeroForOne,
            uint256 swapAmount,
            uint160 swapThreshold
        );
}
