// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @notice Liquity-style trove manager. Used only for reading protocol health.
/// The router does NOT open troves in Phase 1 — these views drive the isRecoveryMode
/// and currentTCR helpers so the front-end (and keepers) can react to stress.
interface ITroveManager {
    /// @param _price Current collateral price in 18-decimal USD.
    function checkRecoveryMode(uint256 _price) external view returns (bool);

    /// @param _price Current collateral price in 18-decimal USD.
    function getTCR(uint256 _price) external view returns (uint256);
}

interface IPriceFeed {
    /// Last price accepted by the oracle circuit-breaker (Liquity convention).
    function lastGoodPrice() external view returns (uint256);
}
