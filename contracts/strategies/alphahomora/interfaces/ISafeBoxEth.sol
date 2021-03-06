// SPDX-License-Identifier: MIT

pragma solidity 0.8.6;
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";

// interface for SafeBox.sol, interest bearing erc20. only include funcs not require gov
interface ISafeBoxEth is IERC20 {
    function cToken() external view returns (address);

    function deposit() external payable;

    function withdraw(uint256 amount) external;

    function claim(uint256 totalAmount, bytes32[] memory proof) external;

    function claimAndWithdraw(
        uint256 totalAmount,
        bytes32[] memory proof,
        uint256 withdrawAmount
    ) external;
}
