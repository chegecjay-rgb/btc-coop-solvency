// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

contract MockOracle {
    uint8 public immutable decimals;

    int256 private _answer;
    uint256 private _updatedAt;
    uint80 private _roundId;
    uint80 private _answeredInRound;

    constructor(uint8 oracleDecimals, int256 initialAnswer, uint256 initialUpdatedAt) {
        decimals = oracleDecimals;
        _answer = initialAnswer;
        _updatedAt = initialUpdatedAt;
        _roundId = 1;
        _answeredInRound = 1;
    }

    function setAnswer(int256 newAnswer) external {
        _answer = newAnswer;
    }

    function setUpdatedAt(uint256 newUpdatedAt) external {
        _updatedAt = newUpdatedAt;
    }

    function setRoundData(
        int256 newAnswer,
        uint256 newUpdatedAt,
        uint80 newRoundId,
        uint80 newAnsweredInRound
    ) external {
        _answer = newAnswer;
        _updatedAt = newUpdatedAt;
        _roundId = newRoundId;
        _answeredInRound = newAnsweredInRound;
    }

    function latestRoundData()
        external
        view
        returns (
            uint80 roundId,
            int256 answer,
            uint256 startedAt,
            uint256 updatedAt,
            uint80 answeredInRound
        )
    {
        return (_roundId, _answer, _updatedAt, _updatedAt, _answeredInRound);
    }
}
