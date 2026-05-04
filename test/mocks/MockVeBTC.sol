// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IVeBTC} from "../../src/interfaces/IVeBTC.sol";

/// @dev Faithful ve-token mock: tracks the locked balance and end timestamp.
///      Does NOT implement decay — balanceOf returns locked amount directly.
///      Tests that depend on veBTC voting power should use a real fork instead.
contract MockVeBTC is IVeBTC {
    using SafeERC20 for IERC20;

    IERC20 public immutable token;
    mapping(address => LockedBalance) private _locked;

    constructor(address _token) {
        token = IERC20(_token);
    }

    function create_lock(uint256 value, uint256 unlock_time) external override {
        require(_locked[msg.sender].amount == 0, "MockVeBTC: already locked");
        require(unlock_time > block.timestamp, "MockVeBTC: unlock in past");
        token.safeTransferFrom(msg.sender, address(this), value);
        _locked[msg.sender] = LockedBalance({amount: int128(int256(value)), end: unlock_time});
    }

    function increase_amount(uint256 value) external override {
        require(_locked[msg.sender].amount > 0, "MockVeBTC: no lock");
        token.safeTransferFrom(msg.sender, address(this), value);
        _locked[msg.sender].amount += int128(int256(value));
    }

    function increase_unlock_time(uint256 unlock_time) external override {
        require(_locked[msg.sender].amount > 0, "MockVeBTC: no lock");
        require(unlock_time > _locked[msg.sender].end, "MockVeBTC: not extending");
        _locked[msg.sender].end = unlock_time;
    }

    function withdraw() external override {
        LockedBalance memory lb = _locked[msg.sender];
        require(lb.amount > 0, "MockVeBTC: nothing locked");
        require(block.timestamp >= lb.end, "MockVeBTC: lock not expired");
        uint256 value = uint256(uint128(lb.amount));
        delete _locked[msg.sender];
        token.safeTransfer(msg.sender, value);
    }

    function locked(address addr) external view override returns (LockedBalance memory) {
        return _locked[addr];
    }

    function balanceOf(address addr) external view override returns (uint256) {
        return uint256(uint128(_locked[addr].amount));
    }

    function totalSupply() external pure override returns (uint256) {
        return 0;
    }
}
