/* Copyright (c) 2020 tevador <tevador@gmail.com> */
/* See LICENSE for licensing information */

#ifndef INSTRUCTION_H
#define INSTRUCTION_H

#include <stdint.h>

typedef enum instr_type {
	INSTR_UMULH_R,   /* unsigned high multiplication by a register */
	INSTR_SMULH_R,   /* signed high multiplication by a register */
	INSTR_MUL_R,     /* multiplication by a register */
	INSTR_SUB_R,     /* subtraction of a register */
	INSTR_XOR_R,     /* xor with a register */
	INSTR_ADD_RS,    /* addition of a shifted register */
	INSTR_ROR_C,     /* rotation by a constant */
	INSTR_ADD_C,     /* addition of a constant */
	INSTR_XOR_C,     /* xor with a constant */
	INSTR_TARGET,    /* branch instruction target */
	INSTR_BRANCH,    /* conditional branch */
} instr_type;

typedef struct instruction {
	instr_type opcode;
	int src;
	int dst;
	uint32_t imm32;
	uint32_t op_par;
} instruction;

#endif
