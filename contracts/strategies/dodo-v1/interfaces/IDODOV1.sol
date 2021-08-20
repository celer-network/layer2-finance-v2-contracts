// SPDX-License-Identifier: Apache-2.0

pragma solidity 0.8.6;

interface IDODOV1 {
    function init(
        address owner,
        address supervisor,
        address maintainer,
        address baseToken,
        address quoteToken,
        address oracle,
        uint256 lpFeeRate,
        uint256 mtFeeRate,
        uint256 k,
        uint256 gasPriceLimit
    ) external;

    function transferOwnership(address newOwner) external;

    function claimOwnership() external;

    function sellBaseToken(
        uint256 amount,
        uint256 minReceiveQuote,
        bytes calldata data
    ) external returns (uint256);

    function buyBaseToken(
        uint256 amount,
        uint256 maxPayQuote,
        bytes calldata data
    ) external returns (uint256);

    function querySellBaseToken(uint256 amount) external view returns (uint256 receiveQuote);

    function queryBuyBaseToken(uint256 amount) external view returns (uint256 payQuote);

    function depositBase(uint256 amount) external returns (uint256);

    function depositBaseTo(address to, uint256 amount) external returns (uint256);

    function withdrawBase(uint256 amount) external returns (uint256);

    function withdrawBaseTo(address to, uint256 amount) external returns (uint256);

    function withdrawAllBase() external returns (uint256);

    function withdrawAllBaseTo(address to) external returns (uint256);

    function depositQuote(uint256 amount) external returns (uint256);

    function depositQuoteTo(address to, uint256 amount) external returns (uint256);

    function withdrawQuote(uint256 amount) external returns (uint256);

    function withdrawQuoteTo(address to, uint256 amount) external returns (uint256);

    function withdrawAllQuote() external returns (uint256);

    function withdrawAllQuoteTo(address to) external returns (uint256);

    function _BASE_CAPITAL_TOKEN_() external returns (address);

    function _QUOTE_CAPITAL_TOKEN_() external returns (address);

    function _BASE_TOKEN_() external view returns (address);

    function _QUOTE_TOKEN_() external view returns (address);

    function _R_STATUS_() external view returns (uint8);

    function _QUOTE_BALANCE_() external view returns (uint256);

    function _BASE_BALANCE_() external view returns (uint256);

    function _K_() external view returns (uint256);

    function _MT_FEE_RATE_() external view returns (uint256);

    function _LP_FEE_RATE_() external view returns (uint256);

    function getExpectedTarget() external view returns (uint256 baseTarget, uint256 quoteTarget);

    function getLpBaseBalance(address lp) external view returns (uint256);

    function getLpQuoteBalance(address lp) external view returns (uint256);

    function getTotalBaseCapital() external view returns (uint256);

    function getTotalQuoteCapital() external view returns (uint256);

    function getBaseCapitalBalanceOf(address lp) external view returns (uint256);

    function getQuoteCapitalBalanceOf(address lp) external view returns (uint256);

    function getOraclePrice() external view returns (uint256);

    function getMidPrice() external view returns (uint256 midPrice);
}
