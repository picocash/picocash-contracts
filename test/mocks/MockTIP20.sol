// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.24;

/// @notice Minimal TIP-20 stand-in for tests: balances, allowances, and the
///         memo transfer with Tempo's event shape (memo is INDEXED, as on the
///         real chain — verified against a Moderato receipt).
contract MockTIP20 {
    string public constant symbol = "mockUSD";
    uint8 public constant decimals = 6;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    event Transfer(address indexed from, address indexed to, uint256 amount);
    event TransferWithMemo(address indexed from, address indexed to, uint256 amount, bytes32 indexed memo);

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        return true;
    }

    function transfer(address to, uint256 amount) public returns (bool) {
        require(balanceOf[msg.sender] >= amount, "insufficient");
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        emit Transfer(msg.sender, to, amount);
        return true;
    }

    function transferWithMemo(address to, uint256 amount, bytes32 memo) external returns (bool) {
        transfer(to, amount);
        emit TransferWithMemo(msg.sender, to, amount, memo);
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        require(allowance[from][msg.sender] >= amount, "allowance");
        require(balanceOf[from] >= amount, "insufficient");
        allowance[from][msg.sender] -= amount;
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        emit Transfer(from, to, amount);
        return true;
    }
}
