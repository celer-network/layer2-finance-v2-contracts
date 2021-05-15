// SPDX-License-Identifier: MIT

pragma solidity >=0.8.0 <0.9.0;

library ErrMsg {
    string internal constant REQ_NOT_OPER = "caller not operator";
    string internal constant REQ_BAD_AMOUNT = "invalid amount";
    string internal constant REQ_NO_WITHDRAW = "withdraw failed";
    string internal constant REQ_BAD_BLOCKID = "invalid block ID";
    string internal constant REQ_BAD_CHALLENGE = "challenge period error";
    string internal constant REQ_BAD_HASH = "invalid data hash";
    string internal constant REQ_BAD_LEN = "invalid data length";
    string internal constant REQ_NO_DRAIN = "drain failed";
    string internal constant REQ_BAD_ASSET = "invalid asset";
    string internal constant REQ_BAD_ST = "invalid strategy";
    string internal constant REQ_OVER_LIMIT = "exceeds limit";
    string internal constant REQ_BAD_DEP_TN = "invalid deposit tn";
    string internal constant REQ_BAD_EXECRES_TN = "invalid execRes tn";
    string internal constant REQ_ZERO_ACCT = "need 0 accounts";
    string internal constant REQ_ONE_ACCT = "need 1 account";
    string internal constant REQ_TWO_ACCT = "need 2 accounts";
    string internal constant REQ_ACCT_NOT_EMPTY = "account not empty";
    string internal constant REQ_BAD_ACCT = "wrong account";
    string internal constant REQ_BAD_SIG = "invalid signature";
    string internal constant REQ_BAD_TS = "old timestamp";
    string internal constant REQ_NO_PEND = "no pending info";
    string internal constant REQ_BAD_SHARES = "wrong shares";
    string internal constant REQ_BAD_AGGR = "wrong aggregate ID";
    string internal constant REQ_ST_NOT_EMPTY = "strategy not empty";
    string internal constant REQ_NO_FRAUD = "no fraud found";
    string internal constant REQ_BAD_NTREE = "bad n-tree verify";
    string internal constant REQ_BAD_SROOT = "state roots not equal";
    string internal constant REQ_BAD_INDEX = "wrong proof index";
    string internal constant REQ_BAD_PREV_TN = "invalid prev tn";
    string internal constant REQ_TN_NOT_IN = "tn not in block";
    string internal constant REQ_TN_NOT_SEQ = "tns not sequential";
    string internal constant REQ_BAD_MERKLE = "failed Merkle proof check";
}
