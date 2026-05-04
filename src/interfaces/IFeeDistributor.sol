// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @notice Protocol fee distributor. Mirrors the veCRV FeeDistributor surface.
/// Fees accrue to the address that holds veBTC; the router claims on behalf of all depositors.
interface IFeeDistributor {
    /// @return amount Fee tokens transferred to `addr`.
    function claim(address addr) external returns (uint256 amount);

    /// @return amount Claimable fee balance without state change.
    function claimable(address addr) external view returns (uint256 amount);

    /// @return The ERC-20 token fees are denominated in (e.g. LUSD, USDC).
    function token() external view returns (address);
}
