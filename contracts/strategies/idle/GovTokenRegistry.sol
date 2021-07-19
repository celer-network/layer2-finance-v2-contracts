// SPDX-License-Identifier: MIT
pragma solidity 0.8.6;

import "@openzeppelin/contracts/access/Ownable.sol";

contract GovTokenRegistry is Ownable {
    // Array of governance token addresses
    // Governance tokens are ditributed by Idle finance
    address[] public govTokens;
    uint govTokensLength;

    event GovTokenRegistered(address govTokenAddress);
    event GovTokenUnregistered(address govTokenAddress);

    constructor(
        address _comp,
        address _idle,
        address _aave
    ){
        govTokens.push(_comp);
        govTokens.push(_idle);
        govTokens.push(_aave);
        govTokensLength = 3;
    }

    function getGovTokens() public view returns (address[] memory) {
        return govTokens;
    }

    function getGovTokensLength() public view returns (uint) {
        return govTokensLength;
    }

    /**
     * @notice Register a governance token which can swap on sushiswap
     * @param _govToken The governance token address
     */
    function registerGovToken(address _govToken) external onlyOwner {
        require(_govToken != address(0), "Invalid governance token");
        if (govTokensLength < govTokens.length) {
          govTokens[govTokensLength] = _govToken;
        } else {
          govTokens.push(_govToken);
        }
        govTokensLength++;

        emit GovTokenRegistered(_govToken);
    }

    /**
     * @notice Unregister a govenance token when Idle finance does not support token
     * @param _govToken The governance token address
     */
    function unregisterGovToken(address _govToken) external onlyOwner {
        require(_govToken != address(0), "Invalid governance token");
        for (uint i = 0; i < govTokensLength; i++) {
            if (govTokens[i] == _govToken) {
                govTokens[i] = govTokens[govTokensLength-1];
                delete govTokens[govTokensLength-1];
                govTokensLength--;

                emit GovTokenUnregistered(_govToken);
            }
        }
    }
}
