// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

interface AggregatorV3Interface {
    function latestRoundData() external view returns (
        uint80 roundId,
        int256 answer,
        uint256 startedAt,
        uint256 updatedAt,
        uint80 answeredInRound
    );
    function decimals() external view returns (uint8);
}

interface IV_cTokenMinimalUnderlyingResolver {
    function underlying() external view returns (address);
}

contract VibeOracleHybridV3 {
    address public admin;
    uint256 public maxStaleness;     // segundos
    uint256 public maxDeviationBps;  // 100 = 1%

    mapping(address => address) public feeds;
    mapping(address => uint256) public manualPrices;

    event FeedSet(address indexed token, address indexed feed);
    event ManualPriceSet(address indexed token, uint256 price);
    event AdminTransferred(address indexed oldAdmin, address indexed newAdmin);
    event ParamsUpdated(uint256 maxStaleness, uint256 maxDeviationBps);

    modifier onlyAdmin() { require(msg.sender == admin, "oracle: !admin"); _; }

    constructor(uint256 _maxStaleness, uint256 _maxDevBps) {
        admin = msg.sender;
        maxStaleness = _maxStaleness;
        maxDeviationBps = _maxDevBps;
    }

    function setFeed(address token, address feed) external onlyAdmin {
        feeds[token] = feed;
        emit FeedSet(token, feed);
    }

    function setManualPrice(address token, uint256 price) external onlyAdmin {
        manualPrices[token] = price;
        emit ManualPriceSet(token, price);
    }

    function setParams(uint256 _staleness, uint256 _dev) external onlyAdmin {
        maxStaleness = _staleness;
        maxDeviationBps = _dev;
        emit ParamsUpdated(_staleness, _dev);
    }

    function transferAdmin(address newAdmin) external onlyAdmin {
        require(newAdmin != address(0), "oracle: zero");
        emit AdminTransferred(admin, newAdmin);
        admin = newAdmin;
    }

    function getUnderlyingPrice(address asset) public view returns (uint256) {
        address token = _resolveUnderlying(asset);
        address feed = feeds[token];
        uint256 manual = manualPrices[token];
        uint256 feedPrice = 0;

        if (feed != address(0)) {
            try AggregatorV3Interface(feed).latestRoundData() returns (
                uint80 roundId,
                int256 answer,
                uint256,
                uint256 updatedAt,
                uint80 answeredInRound
            ) {
                if (answer > 0 && answeredInRound >= roundId && block.timestamp - updatedAt <= maxStaleness) {
                    uint8 dec = AggregatorV3Interface(feed).decimals();
                    feedPrice = _scale(uint256(answer), dec);
                }
            } catch {}
        }

        if (feedPrice == 0) return manual;
        if (manual == 0) return feedPrice;

        uint256 diff = feedPrice > manual ? feedPrice - manual : manual - feedPrice;
        uint256 deviationBps = diff * 10_000 / manual;
        if (deviationBps > maxDeviationBps) {
            return feedPrice < manual ? feedPrice : manual;
        }
        return (feedPrice + manual) / 2;
    }

    function _scale(uint256 price, uint8 decimals_) internal pure returns (uint256) {
        if (decimals_ == 18) return price;
        if (decimals_ < 18) return price * (10 ** (18 - decimals_));
        return price / (10 ** (decimals_ - 18));
    }

    function _resolveUnderlying(address asset) internal view returns (address) {
        (bool ok, bytes memory data) = asset.staticcall(
            abi.encodeWithSelector(IV_cTokenMinimalUnderlyingResolver.underlying.selector)
        );
        if (ok && data.length >= 32) return abi.decode(data, (address));
        return asset;
    }
}