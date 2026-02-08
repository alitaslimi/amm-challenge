// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {AMMStrategyBase} from "./AMMStrategyBase.sol";
import {IAMMStrategy, TradeInfo} from "./IAMMStrategy.sol";

/// @title Adaptive Strategy
/// @notice Dynamic fee strategy that adapts to market conditions
/// @dev Detects arbitrage patterns and adjusts fees to maximize edge
contract AdaptiveStrategy is AMMStrategyBase {
    // Storage slot layout:
    // slots[0]: current bid fee (WAD)
    // slots[1]: current ask fee (WAD)
    // slots[2]: last trade timestamp
    // slots[3]: last trade size (Y amount)
    // slots[4]: recent trade count (for pattern detection)
    // slots[5]: last reserve X
    // slots[6]: last reserve Y
    // slots[7]: base fee (WAD)
    
    uint256 private constant BASE_FEE = 25 * BPS; // Start slightly below normalizer
    uint256 private constant MIN_FEE_DYNAMIC = 20 * BPS;
    uint256 private constant MAX_FEE_DYNAMIC = 80 * BPS;
    uint256 private constant LARGE_TRADE_THRESHOLD = WAD / 20; // 5% of reserves
    uint256 private constant ARB_DETECTION_WINDOW = 5; // trades within 5 steps
    uint256 private constant FEE_ADJUSTMENT_STEP = 2 * BPS; // 2 bps adjustments

    function afterInitialize(uint256 initialX, uint256 initialY) 
        external 
        override 
        returns (uint256 bidFee, uint256 askFee) 
    {
        // Initialize with base fee
        slots[0] = BASE_FEE; // bid fee
        slots[1] = BASE_FEE; // ask fee
        slots[2] = 0; // timestamp
        slots[3] = 0; // last trade size
        slots[4] = 0; // trade count
        slots[5] = initialX; // last reserve X
        slots[6] = initialY; // last reserve Y
        slots[7] = BASE_FEE; // base fee
        
        return (BASE_FEE, BASE_FEE);
    }

    function afterSwap(TradeInfo calldata trade) 
        external 
        override 
        returns (uint256 bidFee, uint256 askFee) 
    {
        uint256 currentBidFee = slots[0];
        uint256 currentAskFee = slots[1];
        uint256 lastTimestamp = slots[2];
        uint256 lastTradeSize = slots[3];
        uint256 tradeCount = slots[4];
        uint256 lastReserveX = slots[5];
        uint256 lastReserveY = slots[6];
        uint256 baseFee = slots[7];
        
        // Calculate trade characteristics
        uint256 tradeSizeRatio = wdiv(trade.amountY, trade.reserveY);
        uint256 timeSinceLastTrade = trade.timestamp > lastTimestamp ? trade.timestamp - lastTimestamp : 1;
        uint256 reserveChangeX = absDiff(trade.reserveX, lastReserveX);
        uint256 reserveChangeY = absDiff(trade.reserveY, lastReserveY);
        uint256 reserveChangeRatio = wdiv(reserveChangeX + reserveChangeY, lastReserveX + lastReserveY);
        
        // Detect arbitrage patterns
        bool isLikelyArb = false;
        
        // Pattern 1: Large trade relative to reserves
        if (tradeSizeRatio > LARGE_TRADE_THRESHOLD) {
            isLikelyArb = true;
        }
        
        // Pattern 2: Rapid consecutive trades (arbitrageurs often trade quickly)
        if (timeSinceLastTrade <= ARB_DETECTION_WINDOW && tradeCount > 0) {
            isLikelyArb = true;
        }
        
        // Pattern 3: Large reserve changes (arbitrage moves reserves significantly)
        if (reserveChangeRatio > LARGE_TRADE_THRESHOLD) {
            isLikelyArb = true;
        }
        
        // Pattern 4: Trade size similar to previous (arbitrageurs often repeat)
        if (lastTradeSize > 0) {
            uint256 sizeSimilarity = wdiv(
                absDiff(trade.amountY, lastTradeSize),
                lastTradeSize
            );
            if (sizeSimilarity < WAD / 10) { // Within 10% of previous trade
                isLikelyArb = true;
            }
        }
        
        // Adjust fees based on detection
        if (isLikelyArb) {
            // Increase fees to reduce arbitrage profitability
            currentBidFee = clampFee(currentBidFee + FEE_ADJUSTMENT_STEP);
            currentAskFee = clampFee(currentAskFee + FEE_ADJUSTMENT_STEP);
        } else {
            // Likely retail - decrease fees to attract more volume
            // But don't go below base fee too quickly
            if (currentBidFee > baseFee) {
                currentBidFee = clampFee(currentBidFee - FEE_ADJUSTMENT_STEP / 2);
            } else if (currentBidFee < baseFee) {
                // Gradually move back to base fee
                currentBidFee = clampFee(currentBidFee + FEE_ADJUSTMENT_STEP / 4);
            }
            
            if (currentAskFee > baseFee) {
                currentAskFee = clampFee(currentAskFee - FEE_ADJUSTMENT_STEP / 2);
            } else if (currentAskFee < baseFee) {
                currentAskFee = clampFee(currentAskFee + FEE_ADJUSTMENT_STEP / 4);
            }
        }
        
        // Asymmetric fee adjustment based on trade direction
        // If it's a buy (AMM buys X), we might want to adjust ask fee differently
        // If it's a sell (AMM sells X), we might want to adjust bid fee differently
        if (trade.isBuy) {
            // AMM bought X - trader sold X
            // If this was retail, we want lower ask fee to attract more sellers
            // If this was arb, we already increased both fees above
            if (!isLikelyArb && currentAskFee > MIN_FEE_DYNAMIC) {
                currentAskFee = clampFee(currentAskFee - FEE_ADJUSTMENT_STEP / 4);
            }
        } else {
            // AMM sold X - trader bought X
            // If this was retail, we want lower bid fee to attract more buyers
            if (!isLikelyArb && currentBidFee > MIN_FEE_DYNAMIC) {
                currentBidFee = clampFee(currentBidFee - FEE_ADJUSTMENT_STEP / 4);
            }
        }
        
        // Ensure fees stay within reasonable bounds
        currentBidFee = clamp(currentBidFee, MIN_FEE_DYNAMIC, MAX_FEE_DYNAMIC);
        currentAskFee = clamp(currentAskFee, MIN_FEE_DYNAMIC, MAX_FEE_DYNAMIC);
        
        // Update storage
        slots[0] = currentBidFee;
        slots[1] = currentAskFee;
        slots[2] = trade.timestamp;
        slots[3] = trade.amountY;
        slots[4] = timeSinceLastTrade <= ARB_DETECTION_WINDOW ? tradeCount + 1 : 1;
        slots[5] = trade.reserveX;
        slots[6] = trade.reserveY;
        
        return (currentBidFee, currentAskFee);
    }

    function getName() external pure override returns (string memory) {
        return "AdaptiveStrategy";
    }
}
