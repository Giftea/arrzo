// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @notice veCRV-style vote-escrowed BTC locking interface.
/// Weeks are the rounding unit for unlock times (matches ve-token convention).
interface IVeBTC {
    struct LockedBalance {
        int128 amount;
        uint256 end; // epoch-week boundary
    }

    function create_lock(uint256 value, uint256 unlock_time) external;

    function increase_amount(uint256 value) external;

    function increase_unlock_time(uint256 unlock_time) external;

    function withdraw() external;

    function locked(address addr) external view returns (LockedBalance memory);

    function balanceOf(address addr) external view returns (uint256);

    function totalSupply() external view returns (uint256);
}
