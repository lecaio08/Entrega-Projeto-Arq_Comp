// =============================================================================
// pl_control.sv
// Unidade de Controle Principal -- RV32I pipelined (P&H secao 4.4)
//
// Decodifica o opcode de 7 bits (estagio ID) e gera os sinais de controle
// que serao propagados pelos registradores de pipeline.
//
// Instrucoes suportadas:
//   R-type  (0110011): add, and
//   I-type  (0000011): lw
//   S-type  (0100011): sw
//   B-type  (1100011): beq
//   I-type  (0010011): addi, andi, ori, slti, slli, srli, srai
//   U-type  (0110111): lui
//   U-type  (0010111): auipc
//   J-type  (1101111): jal
//   I-type  (1100111): jalr
//
// Tabela de sinais de controle:
//   Sinal     | R-type | lw | sw | beq
//   ----------|--------|----|----|-----
//   ALUSrc    |   0    |  1 |  1 |  0    0=reg, 1=imm
//   MemtoReg  |   0    |  1 |  - |  -    0=ALU, 1=mem
//   RegWrite  |   1    |  1 |  0 |  0
//   MemRead   |   0    |  1 |  0 |  0
//   MemWrite  |   0    |  0 |  1 |  0
//   Branch    |   0    |  0 |  0 |  1
//   ALUOp[1]  |   1    |  0 |  0 |  0
//   ALUOp[0]  |   0    |  0 |  0 |  1
// =============================================================================

`timescale 1ns / 1ps

module pl_control (
    input  logic [6:0] Opcode,
    output logic       ALUSrc,
    output logic       MemtoReg,
    output logic       RegWrite,
    output logic       MemRead,
    output logic       MemWrite,
    output logic       Branch,
    output logic [1:0] ALUOp,
    output logic [1:0] ASrc,      // origem de SrcA: 00=rs1, 01=PC, 10=zero
    output logic [1:0] Jump       // 00=nenhum, 01=JAL, 10=JALR
);

    localparam R_TYPE = 7'b0110011;
    localparam LOAD   = 7'b0000011;
    localparam STORE  = 7'b0100011;
    localparam BRANCH = 7'b1100011;
    localparam OP_IMM = 7'b0010011;
    localparam LUI    = 7'b0110111;
    localparam AUIPC  = 7'b0010111;
    localparam JAL    = 7'b1101111;
    localparam JALR   = 7'b1100111;

    always_comb begin
        ALUSrc   = 1'b0;
        MemtoReg = 1'b0;
        RegWrite = 1'b0;
        MemRead  = 1'b0;
        MemWrite = 1'b0;
        Branch   = 1'b0;
        ALUOp    = 2'b00;
        ASrc     = 2'b00;
        Jump     = 2'b00;

        case (Opcode)
            R_TYPE: begin
                ALUSrc   = 1'b0;
                MemtoReg = 1'b0;
                RegWrite = 1'b1;
                ALUOp    = 2'b10;
            end
            LOAD: begin
                ALUSrc   = 1'b1;
                MemtoReg = 1'b1;
                RegWrite = 1'b1;
                MemRead  = 1'b1;
                ALUOp    = 2'b00;
            end
            STORE: begin
                ALUSrc   = 1'b1;
                MemWrite = 1'b1;
                ALUOp    = 2'b00;
            end
            BRANCH: begin
                Branch   = 1'b1;
                ALUOp    = 2'b01;
            end
            OP_IMM: begin
                ALUSrc   = 1'b1;
                RegWrite = 1'b1;
                ALUOp    = 2'b11;
            end
            // LUI/AUIPC: ALU soma imm_U a SrcA; ASrc escolhe o que entra em SrcA
            LUI: begin
                ALUSrc   = 1'b1;
                RegWrite = 1'b1;
                ALUOp    = 2'b00;      // ADD: 0 + imm
                ASrc     = 2'b10;
            end
            AUIPC: begin
                ALUSrc   = 1'b1;
                RegWrite = 1'b1;
                ALUOp    = 2'b00;      // ADD: PC + imm
                ASrc     = 2'b01;
            end
            // JAL/JALR: o desvio em si e feito em EX (pl_datapath) via Jump; aqui so
            // habilita o write-back (rd <- PC+4). JALR usa a ALU p/ calcular rs1+imm.
            JAL: begin
                RegWrite = 1'b1;       // rd <- PC+4 (feito em EX)
                Jump     = 2'b01;
            end
            JALR: begin
                ALUSrc   = 1'b1;       // alvo = rs1 + imm (ALU: ADD)
                RegWrite = 1'b1;
                ALUOp    = 2'b00;
                Jump     = 2'b10;
            end
            default: ; // sinais permanecem em zero (seguro)
        endcase
    end

endmodule
