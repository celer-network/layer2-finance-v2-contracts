// SPDX-License-Identifier: MIT

pragma solidity 0.8.6;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

contract Faucet is Ownable {
    using SafeERC20 for IERC20;

    /**
     * @dev Sends 0.01% of each token to the caller.
     * @param tokens The tokens to drip.
     */
    function drip(address[] calldata tokens) public {
        for (uint256 i = 0; i < tokens.length; i++) {
            IERC20 token = IERC20(tokens[i]);
            uint256 balance = token.balanceOf(address(this));
            require(balance > 0, "Faucet is empty");
            token.safeTransfer(msg.sender, balance / 10000); // 0.01%
        }
    }

    /**
     * @dev Owner drains one type of tokens
     *
     * @param _asset drained asset address
     * @param _amount drained asset amount
     */
    function drainToken(address _asset, uint256 _amount) external onlyOwner {
        IERC20(_asset).safeTransfer(msg.sender, _amount);
    }
}
