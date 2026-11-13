// =============================================================================
// pl_datapath.sv
// Datapath pipeline de 5 estagios -- RV32I (P&H secoes 4.6-4.10)
//
// Estagios:
//   IF  -- busca instrucao (pl_imem, PC)
//   ID  -- decodificacao, leitura de registradores, deteccao de hazard
//   EX  -- execucao (ALU), resolucao de branch, forwarding
//   MEM -- acesso a memoria de dados / MMIO
//   WB  -- escrita no banco de registradores
//
// Tratamento de hazards:
//   Load-use stall : 1 ciclo de bolha (pl_hazard)
//   RAW data       : forwarding EX/MEM -> EX e MEM/WB -> EX (pl_forward)
//   Branch taken   : flush de IF e ID (2 NOPs) na resolucao em EX
//
// Decodificacao de endereco (estagio MEM):
//   alu_result[10] = 0 -> memoria de dados  (0x000-0x3FF)
//   alu_result[10] = 1 -> MMIO              (0x400-0x7FF)
//     alu_result[4:2] seleciona periferico dentro da janela MMIO
// =============================================================================

`timescale 1ns / 1ps

import pl_pipe_pkg::*;

module pl_datapath (
    input  logic        clk,
    input  logic        rst_n,

    // Sinais de controle vindos do estagio ID (pl_control)
    input  logic        ALUSrc,
    input  logic [1:0]  ASrc,       // origem de SrcA (LUI/AUIPC): 00=rs1, 01=PC, 10=zero
    input  logic [1:0]  Jump,       // 00=nenhum, 01=JAL, 10=JALR (resolvidos em EX)
    input  logic        MemtoReg,
    input  logic        RegWrite,
    input  logic        MemRead,
    input  logic        MemWrite,
    input  logic        Branch,
    input  logic [1:0]  ALUOp,

    // Codigo de operacao da ALU (pl_alu_ctrl, usa campos do estagio EX)
    input  logic [3:0]  ALU_CC,

    // Campos realimentados ao pl_cpu para controle e ALU ctrl
    output logic [6:0]  Opcode,       // opcode do estagio ID (para pl_control)
    output logic [2:0]  Funct3_EX,    // funct3 do estagio EX (para pl_alu_ctrl)
    output logic [6:0]  Funct7_EX,    // funct7 do estagio EX (para pl_alu_ctrl)
    output logic [1:0]  ALUOp_EX,     // ALUOp do estagio EX  (para pl_alu_ctrl)

    output logic [31:0] PC,           // PC atual (testbench / debug)

    // E/S Mapeada em Memoria -- DE2-115
    input  logic [17:0] SW,
    input  logic [3:0]  KEY,
    output logic [17:0] LEDR,
    output logic [8:0]  LEDG,
    output logic        UART_TXD,
    input  logic        UART_RXD,

    // Observabilidade para o testbench
    output logic        wb_reg_write,   // pulso quando WB escreve registrador
    output logic [4:0]  wb_reg_dst,     // registrador destino (WB)
    output logic [31:0] wb_reg_data,    // dado escrito (WB)
    output logic        mem_wr_en,      // escrita na dmem (nao MMIO)
    output logic [7:0]  mem_wr_addr,    // endereco de palavra da dmem (MEM)
    output logic [31:0] mem_wr_data     // dado escrito na dmem (MEM)
);

    // =========================================================================
    // Sinais internos
    // =========================================================================

    // PC
    logic [31:0] pc_reg, pc_plus4;

    // Registradores de pipeline
    if_id_t  if_id;
    id_ex_t  id_ex;
    ex_mem_t ex_mem;
    mem_wb_t mem_wb;

    // Hazard / branch
    logic        stall;
    logic        pc_src;
    logic [31:0] branch_target;

    // ID
    logic [31:0] rd1, rd2, imm_ext;

    // EX -- forwarding
    logic [1:0]  fwd_a, fwd_b;
    logic [31:0] fwd_srca, fwd_srcb, alu_srca, alu_srcb;
    logic [31:0] alu_result;
    logic        zero;
    logic        take_branch;     // condicao do desvio avaliada em EX (ver abaixo)
    logic [31:0] ex_result;       // resultado de EX: ALU ou PC+4 (JAL/JALR)
    // MEM: SB/SH (mascara + palavra a escrever) e LB/LH/LBU/LHU (byte ja alinhado + valor final)
    logic [31:0] store_mask, store_word, load_shifted, load_data;

    // WB
    logic [31:0] wb_data;

    // MEM
    logic        mmio_sel;
    logic [31:0] dmem_rd, mmio_rd, mem_read_data;

    // =========================================================================
    // IF -- Busca de instrucao
    // =========================================================================
    logic [31:0] instr_if;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n)      pc_reg <= 32'b0;
        else if (pc_src) pc_reg <= branch_target;   // branch tem prioridade
        else if (!stall) pc_reg <= pc_plus4;
        // else stall: PC mantido
    end

    assign PC       = pc_reg;
    assign pc_plus4 = pc_reg + 32'd4;

    pl_imem imem (
        .addr  (pc_reg[9:2]),
        .instr (instr_if)
    );

    // =========================================================================
    // Registrador IF/ID
    // =========================================================================
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin                    // reset assicrono (unico sinal na lista)
            if_id.pc    <= 32'b0;
            if_id.instr <= 32'b0;
        end else if (pc_src) begin           // flush sincrono: branch taken
            if_id.pc    <= 32'b0;
            if_id.instr <= 32'b0;
        end else if (!stall) begin           // avanco normal
            if_id.pc    <= pc_reg;
            if_id.instr <= instr_if;
        end
        // else stall: mantido
    end

    // =========================================================================
    // ID -- Decodificacao, banco de registradores, imediato, hazard
    // =========================================================================
    assign Opcode = if_id.instr[6:0];

    // Deteccao de hazard load-use
    pl_hazard hazard (
        .if_id_rs1      (if_id.instr[19:15]),
        .if_id_rs2      (if_id.instr[24:20]),
        .id_ex_rd       (id_ex.rd),
        .id_ex_mem_read (id_ex.mem_read),
        .stall          (stall)
    );

    // Dado de write-back (mux WB): usado tambem pelo forwarding MEM/WB->EX
    assign wb_data = mem_wb.mem_to_reg ? mem_wb.read_data : mem_wb.alu_result;

    pl_regfile regfile (
        .clk       (clk),
        .RegWrite  (mem_wb.reg_write),
        .rs1       (if_id.instr[19:15]),
        .rs2       (if_id.instr[24:20]),
        .rd        (mem_wb.rd),
        .WriteData (wb_data),
        .ReadData1 (rd1),
        .ReadData2 (rd2)
    );

    pl_sign_ext sign_ext (
        .Instr  (if_id.instr),
        .ImmExt (imm_ext)
    );

    // Saidas para o testbench (estagio WB)
    assign wb_reg_write = mem_wb.reg_write;
    assign wb_reg_dst   = mem_wb.rd;
    assign wb_reg_data  = wb_data;

    // =========================================================================
    // Registrador ID/EX
    // =========================================================================
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin                      // reset assicrono (unico sinal na lista)
            id_ex.alu_src    <= 1'b0;
            id_ex.a_sel      <= 2'b00;
            id_ex.mem_to_reg <= 1'b0;
            id_ex.reg_write  <= 1'b0;
            id_ex.mem_read   <= 1'b0;
            id_ex.mem_write  <= 1'b0;
            id_ex.alu_op     <= 2'b00;
            id_ex.branch     <= 1'b0;
            id_ex.jump       <= 2'b00;
            id_ex.pc         <= 32'b0;
            id_ex.rd1        <= 32'b0;
            id_ex.rd2        <= 32'b0;
            id_ex.rs1        <= 5'b0;
            id_ex.rs2        <= 5'b0;
            id_ex.rd         <= 5'b0;
            id_ex.imm_ext    <= 32'b0;
            id_ex.funct3     <= 3'b0;
            id_ex.funct7     <= 7'b0;
        end else if (stall || pc_src) begin    // NOP sincrono: load-use ou branch
            id_ex.alu_src    <= 1'b0;
            id_ex.a_sel      <= 2'b00;
            id_ex.mem_to_reg <= 1'b0;
            id_ex.reg_write  <= 1'b0;
            id_ex.mem_read   <= 1'b0;
            id_ex.mem_write  <= 1'b0;
            id_ex.alu_op     <= 2'b00;
            id_ex.branch     <= 1'b0;
            id_ex.jump       <= 2'b00;
            id_ex.pc         <= 32'b0;
            id_ex.rd1        <= 32'b0;
            id_ex.rd2        <= 32'b0;
            id_ex.rs1        <= 5'b0;
            id_ex.rs2        <= 5'b0;
            id_ex.rd         <= 5'b0;
            id_ex.imm_ext    <= 32'b0;
            id_ex.funct3     <= 3'b0;
            id_ex.funct7     <= 7'b0;
        end else begin
            id_ex.alu_src    <= ALUSrc;
            id_ex.a_sel      <= ASrc;
            id_ex.mem_to_reg <= MemtoReg;
            id_ex.reg_write  <= RegWrite;
            id_ex.mem_read   <= MemRead;
            id_ex.mem_write  <= MemWrite;
            id_ex.alu_op     <= ALUOp;
            id_ex.branch     <= Branch;
            id_ex.jump       <= Jump;
            id_ex.pc         <= if_id.pc;
            id_ex.rd1        <= rd1;
            id_ex.rd2        <= rd2;
            id_ex.rs1        <= if_id.instr[19:15];
            id_ex.rs2        <= if_id.instr[24:20];
            id_ex.rd         <= if_id.instr[11:7];
            id_ex.imm_ext    <= imm_ext;
            id_ex.funct3     <= if_id.instr[14:12];
            id_ex.funct7     <= if_id.instr[31:25];
        end
    end

    // Realimentacao para pl_alu_ctrl (usa campos do estagio EX)
    assign Funct3_EX = id_ex.funct3;
    assign Funct7_EX = id_ex.funct7;
    assign ALUOp_EX  = id_ex.alu_op;

    // =========================================================================
    // EX -- Forwarding, ALU, resolucao de branch
    // =========================================================================
    pl_forward forward (
        .id_ex_rs1        (id_ex.rs1),
        .id_ex_rs2        (id_ex.rs2),
        .ex_mem_rd        (ex_mem.rd),
        .mem_wb_rd        (mem_wb.rd),
        .ex_mem_reg_write (ex_mem.reg_write),
        .mem_wb_reg_write (mem_wb.reg_write),
        .forward_a        (fwd_a),
        .forward_b        (fwd_b)
    );

    // Mux de forwarding para SrcA
    always_comb begin
        case (fwd_a)
            2'b10:   fwd_srca = ex_mem.alu_result;
            2'b01:   fwd_srca = wb_data;
            default: fwd_srca = id_ex.rd1;
        endcase
    end

    // Mux de forwarding para SrcB (antes do mux ALUSrc)
    always_comb begin
        case (fwd_b)
            2'b10:   fwd_srcb = ex_mem.alu_result;
            2'b01:   fwd_srcb = wb_data;
            default: fwd_srcb = id_ex.rd2;
        endcase
    end

    // Mux de origem de SrcA (operando A da ALU):
    //   00 -> rs1 ja adiantado pelo forwarding (todas as demais instrucoes)
    //   01 -> PC da propria instrucao (AUIPC: rd = PC + imm_U)
    //   10 -> zero                   (LUI:   rd = 0  + imm_U)
    // Fica DEPOIS do mux de forwarding de proposito: em LUI/AUIPC os bits [19:15]
    // da instrucao sao parte do imediato (nao e rs1), entao o forwarding pode
    // escolher um valor sem sentido, que esse mux simplesmente descarta.
    always_comb begin
        case (id_ex.a_sel)
            2'b01:   alu_srca = id_ex.pc;
            2'b10:   alu_srca = 32'b0;
            default: alu_srca = fwd_srca;
        endcase
    end

    // Mux ALUSrc: imediato ou registrador
    assign alu_srcb = id_ex.alu_src ? id_ex.imm_ext : fwd_srcb;

    pl_alu alu (
        .SrcA      (alu_srca),
        .SrcB      (alu_srcb),
        .Operation (ALU_CC),
        .ALUResult (alu_result),
        .Zero      (zero)
    );

    // Branch/jump resolvido no estagio EX (flush de 2 instrucoes se taken)
    //
    // Condicao do desvio, decidida pelo funct3 (a ALU ja foi configurada por
    // pl_alu_ctrl com ALUOp=01 para fazer a operacao certa):
    //   BEQ  (000) / BNE  (001) : ALU faz SUB  -> usa a flag Zero (rs1 == rs2)
    //   BLT  (100) / BGE  (101) : ALU faz SLT  -> alu_result[0] = (rs1 < rs2) com sinal
    //   BLTU (110) / BGEU (111) : ALU faz SLTU -> alu_result[0] = (rs1 < rs2) sem sinal
    // BNE/BGE/BGEU sao simplesmente a negacao de BEQ/BLT/BLTU.
    always_comb begin
        case (id_ex.funct3)
            3'b000:        take_branch = zero;           // BEQ
            3'b001:        take_branch = ~zero;          // BNE
            3'b100, 3'b110: take_branch = alu_result[0]; // BLT, BLTU
            3'b101, 3'b111: take_branch = ~alu_result[0];// BGE, BGEU
            default:       take_branch = 1'b0;
        endcase
    end

    // Alvo do salto:
    //   branch / JAL : PC + imm (imm_B ou imm_J, ja montado em pl_sign_ext)
    //   JALR         : (rs1 + imm_I) com o bit 0 zerado (exigencia da ISA).
    //                  rs1 + imm_I e o proprio alu_result (ALUSrc=1, ALU faz ADD)
    // jump[1] = 1 so no JALR. pc_src = 1 vira flush de IF/ID e ID/EX (as 2
    // instrucoes buscadas depois do salto viram NOP) e carrega o PC com o alvo.
    assign branch_target = id_ex.jump[1] ? {alu_result[31:1], 1'b0}
                                         : id_ex.pc + id_ex.imm_ext;
    assign pc_src        = (id_ex.branch && take_branch) || (id_ex.jump != 2'b00);

    // JAL/JALR gravam PC+4 (endereco de retorno) em rd. Em vez de criar um caminho
    // novo ate o WB, PC+4 entra no lugar do resultado da ALU: assim o mesmo
    // caminho EX/MEM -> MEM/WB -> regfile (e o forwarding existente) ja serve.
    // Para as demais instrucoes ex_result == alu_result (comportamento da base).
    assign ex_result = (id_ex.jump != 2'b00) ? id_ex.pc + 32'd4 : alu_result;

    // =========================================================================
    // Registrador EX/MEM
    // =========================================================================
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            ex_mem.mem_to_reg  <= 1'b0;
            ex_mem.reg_write   <= 1'b0;
            ex_mem.mem_read    <= 1'b0;
            ex_mem.mem_write   <= 1'b0;
            ex_mem.alu_result  <= 32'b0;
            ex_mem.write_data  <= 32'b0;
            ex_mem.rd          <= 5'b0;
            ex_mem.funct3      <= 3'b0;
        end else begin
            ex_mem.mem_to_reg  <= id_ex.mem_to_reg;
            ex_mem.reg_write   <= id_ex.reg_write;
            ex_mem.mem_read    <= id_ex.mem_read;
            ex_mem.mem_write   <= id_ex.mem_write;
            ex_mem.alu_result  <= ex_result;
            ex_mem.write_data  <= fwd_srcb;   // rs2 adiantado (para SW/MMIO)
            ex_mem.rd          <= id_ex.rd;
            ex_mem.funct3      <= id_ex.funct3;
        end
    end

    // =========================================================================
    // MEM -- Memoria de dados + MMIO
    // =========================================================================
    assign mmio_sel = ex_mem.alu_result[10];

    // SB/SH: a dmem so escreve palavras inteiras, entao fazemos read-modify-write:
    // le a palavra atual (dmem_rd, leitura assincrona), troca so os bytes
    // selecionados e escreve a palavra de volta. Nao foi preciso alterar a pl_dmem.
    //   store_mask : 1s nos bytes que o store altera (funct3: 000=SB, 001=SH, 010=SW)
    //   o deslocamento {addr[1:0],3'b000} = 8*addr[1:0] posiciona mascara e dado
    // Exemplo SB em addr[1:0]=2, rs2=0x000000AB, palavra antiga=0x11223344:
    //   mascara=0x00FF0000, dado deslocado=0x00AB0000 -> escreve 0x11AB3344
    // SW: mascara=FFFFFFFF -> escreve write_data inteiro (identico a base).
    // Obs.: SH assume endereco alinhado em 2 bytes. Escrita em MMIO (mmio_sel)
    // continua recebendo rs2 bruto (ex_mem.write_data) -> use SW para LEDs/UART.
    always_comb begin
        case (ex_mem.funct3[1:0])
            2'b00:   store_mask = 32'h000000FF << {ex_mem.alu_result[1:0], 3'b000}; // SB
            2'b01:   store_mask = 32'h0000FFFF << {ex_mem.alu_result[1:0], 3'b000}; // SH
            default: store_mask = 32'hFFFFFFFF;                                     // SW
        endcase
    end
    assign store_word = (dmem_rd & ~store_mask)
                      | ((ex_mem.write_data << {ex_mem.alu_result[1:0], 3'b000}) & store_mask);

    pl_dmem dmem (
        .clk       (clk),
        .MemWrite  (ex_mem.mem_write & ~mmio_sel),
        .addr      (ex_mem.alu_result[9:2]),
        .WriteData (store_word),
        .ReadData  (dmem_rd)
    );

    pl_mmio mmio (
        .clk       (clk),
        .rst_n     (rst_n),
        .MemWrite  (ex_mem.mem_write &  mmio_sel),
        .MemRead   (ex_mem.mem_read  &  mmio_sel),
        .addr      (ex_mem.alu_result[4:2]),
        .WriteData (ex_mem.write_data),
        .SW        (SW),
        .KEY       (KEY),
        .ReadData  (mmio_rd),
        .LEDR      (LEDR),
        .LEDG      (LEDG),
        .UART_TXD  (UART_TXD),
        .UART_RXD  (UART_RXD)
    );

    assign mem_read_data = mmio_sel ? mmio_rd : dmem_rd;

    // Loads: a memoria sempre devolve a palavra inteira. Aqui desloca o byte/meia-
    // palavra pedido para a posicao 0 (load_shifted) e estende para 32 bits:
    //   LB/LH  (000/001): extensao COM sinal (replica o bit mais significativo)
    //   LBU/LHU(100/101): extensao com zeros
    //   LW     (010)    : palavra inteira (default, comportamento da base)
    // Exemplo LB em addr[1:0]=3, palavra=0x80FF7F01: desloca 24 bits -> 0x80,
    //   LB = 0xFFFFFF80, LBU = 0x00000080.
    // O funct3 vem de ex_mem.funct3 (ja existia na base). Vale tambem p/ leitura MMIO.
    assign load_shifted = mem_read_data >> {ex_mem.alu_result[1:0], 3'b000};
    always_comb begin
        case (ex_mem.funct3)
            3'b000:  load_data = {{24{load_shifted[7]}},  load_shifted[7:0]};   // LB
            3'b001:  load_data = {{16{load_shifted[15]}}, load_shifted[15:0]};  // LH
            3'b100:  load_data = {24'b0, load_shifted[7:0]};                    // LBU
            3'b101:  load_data = {16'b0, load_shifted[15:0]};                   // LHU
            default: load_data = mem_read_data;                                 // LW
        endcase
    end

    // Saidas de observabilidade para o testbench
    assign mem_wr_en   = ex_mem.mem_write & ~mmio_sel;
    assign mem_wr_addr = ex_mem.alu_result[9:2];
    assign mem_wr_data = store_word;

    // =========================================================================
    // Registrador MEM/WB
    // =========================================================================
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            mem_wb.mem_to_reg <= 1'b0;
            mem_wb.reg_write  <= 1'b0;
            mem_wb.alu_result <= 32'b0;
            mem_wb.read_data  <= 32'b0;
            mem_wb.rd         <= 5'b0;
        end else begin
            mem_wb.mem_to_reg <= ex_mem.mem_to_reg;
            mem_wb.reg_write  <= ex_mem.reg_write;
            mem_wb.alu_result <= ex_mem.alu_result;
            mem_wb.read_data  <= load_data;
            mem_wb.rd         <= ex_mem.rd;
        end
    end

    // WB: wb_data = mem_to_reg ? read_data : alu_result  (definido acima, no bloco ID)

endmodule
