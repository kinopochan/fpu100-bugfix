// fpu_wb.v — Wishbone wrapper for OpenCores fpu100
//
// Register map (active when selected by top-level address decode):
//   +0x00  OPA      (R/W) Operand A  (IEEE 754 single)
//   +0x04  OPB      (R/W) Operand B  (IEEE 754 single)
//   +0x08  FPU_OP   (R/W) [2:0] operation, [7:4] rmode
//                         Write triggers computation start
//   +0x0C  RESULT   (R)   Result (IEEE 754 single)
//                         Read stalls until ready
//   +0x0C  (W)      Writing any value also triggers start
//                         (re-run with same operands/op)
//
// Operations:  000=add, 001=sub, 010=mul, 011=div, 100=sqrt
// Rounding:    00=nearest-even, 01=zero, 10=up, 11=down
//
// Status flags are available in FPU_OP read-back:
//   [2:0]  fpu_op
//   [7:4]  rmode (as written)
//   [8]    ready
//   [16]   ine (inexact)
//   [17]   overflow
//   [18]   underflow
//   [19]   div_zero
//   [20]   inf
//   [21]   zero
//   [22]   qnan
//   [23]   snan

module fpu_wb (
    input  wire        clk,
    input  wire        rst,

    // Wishbone slave (directly wired, no stb/cyc — top provides)
    input  wire        sel,       // address decode hit
    input  wire        stb,
    input  wire        cyc,
    input  wire        we,
    input  wire [3:0]  adr,       // byte address [3:0] within block
    input  wire [31:0] dat_i,
    output reg  [31:0] dat_o,
    output reg         ack
);

    // ----------------------------------------
    // FPU core signals
    // ----------------------------------------
    reg  [31:0] opa_reg, opb_reg;
    reg  [2:0]  fpu_op_reg;
    reg  [1:0]  rmode_reg;
    reg         fpu_start;

    wire [31:0] fpu_output;
    wire        fpu_ready;
    wire        fpu_ine, fpu_overflow, fpu_underflow;
    wire        fpu_div_zero, fpu_inf, fpu_zero;
    wire        fpu_qnan, fpu_snan;

    // ----------------------------------------
    // FPU core instance
    // ----------------------------------------
    fpu u_fpu (
        .clk_i       (clk),
        .opa_i       (opa_reg),
        .opb_i       (opb_reg),
        .fpu_op_i    (fpu_op_reg),
        .rmode_i     (rmode_reg),
        .output_o    (fpu_output),
        .start_i     (fpu_start),
        .ready_o     (fpu_ready),
        .ine_o       (fpu_ine),
        .overflow_o  (fpu_overflow),
        .underflow_o (fpu_underflow),
        .div_zero_o  (fpu_div_zero),
        .inf_o       (fpu_inf),
        .zero_o      (fpu_zero),
        .qnan_o      (fpu_qnan),
        .snan_o      (fpu_snan)
    );

    // ----------------------------------------
    // Result / flag latches
    // ----------------------------------------
    // fpu100's ready_o is a one-cycle pulse and the status wires are
    // combinational off internal pipeline state, so the bus may read
    // much later than the ready edge.  Latch on the pulse and hand
    // out the latched copy (matches fpu_sp_wb).
    reg         wb_ready;
    reg [31:0]  result_latched;
    reg [7:0]   flags_latched;  // {snan, qnan, zero, inf, div_zero, underflow, overflow, ine}

    // ----------------------------------------
    // Wishbone FSM
    // ----------------------------------------
    // Guard req with ~ack to prevent back-to-back ACK leaking.  Without
    // this, when OP write is immediately followed by RESULT read
    // (back-to-back memory access, same 32-bit fetch word), the ack
    // raised for the write phase spills into the read phase (both
    // share sel=1), and the CPU reads dat_o=0 without stalling.
    wire req = sel & stb & cyc & ~ack;

    localparam S_IDLE     = 2'd0;
    localparam S_WAIT     = 2'd1;  // waiting for FPU ready

    reg [1:0] state;

    always @(posedge clk or posedge rst) begin
        if (rst) begin
            opa_reg        <= 32'd0;
            opb_reg        <= 32'd0;
            fpu_op_reg     <= 3'd0;
            rmode_reg      <= 2'd0;
            fpu_start      <= 1'b0;
            ack            <= 1'b0;
            dat_o          <= 32'd0;
            state          <= S_IDLE;
            wb_ready       <= 1'b0;
            result_latched <= 32'd0;
            flags_latched  <= 8'd0;
        end else begin
            fpu_start <= 1'b0;  // default: one-shot pulse
            ack       <= 1'b0;

            // Latch result, status flags and ready on the 1-cycle pulse.
            if (fpu_ready) begin
                wb_ready       <= 1'b1;
                result_latched <= fpu_output;
                flags_latched  <= {fpu_snan, fpu_qnan,
                                   fpu_zero, fpu_inf,
                                   fpu_div_zero, fpu_underflow,
                                   fpu_overflow, fpu_ine};
            end

            case (state)
                S_IDLE: begin
                    if (req) begin
                        case (adr[3:2])
                            2'd0: begin  // +0x00 OPA
                                if (we) opa_reg <= dat_i;
                                else    dat_o   <= opa_reg;
                                ack <= 1'b1;
                            end
                            2'd1: begin  // +0x04 OPB
                                if (we) opb_reg <= dat_i;
                                else    dat_o   <= opb_reg;
                                ack <= 1'b1;
                            end
                            2'd2: begin  // +0x08 FPU_OP
                                if (we) begin
                                    fpu_op_reg <= dat_i[2:0];
                                    rmode_reg  <= dat_i[5:4];
                                    fpu_start  <= 1'b1;
                                    wb_ready   <= 1'b0;  // invalidate; overrides fpu_ready latch above
                                end else begin
                                    // 32-bit layout (matches fpu_sp_wb exactly):
                                    //   [2:0]   fpu_op
                                    //   [3]     0
                                    //   [6:4]   rmode (2-bit rmode zero-extended)
                                    //   [7]     0
                                    //   [8]     ready
                                    //   [15:9]  0
                                    //   [23:16] flags {snan,qnan,zero,inf,dz,uf,of,ine}
                                    //   [31:24] 0
                                    dat_o <= {8'd0,
                                              flags_latched,      // [23:16]
                                              7'd0,               // [15:9]
                                              wb_ready,           // [8]
                                              1'b0,               // [7]
                                              1'b0, rmode_reg,    // [6:4] 3-bit (msb zero)
                                              1'b0,               // [3]
                                              fpu_op_reg};        // [2:0]
                                end
                                ack <= 1'b1;
                            end
                            2'd3: begin  // +0x0C RESULT
                                if (we) begin
                                    // Write to RESULT = re-start
                                    fpu_start <= 1'b1;
                                    wb_ready  <= 1'b0;
                                    ack <= 1'b1;
                                end else begin
                                    // Read: stall until wb_ready (always
                                    // through S_WAIT, no shortcut — the
                                    // latch might update this same cycle).
                                    state <= S_WAIT;
                                end
                            end
                        endcase
                    end
                end

                S_WAIT: begin
                    // Waiting for FPU to complete; return the latched
                    // result (stable even if the FPU is re-started).
                    if (wb_ready) begin
                        dat_o <= result_latched;
                        ack   <= 1'b1;
                        state <= S_IDLE;
                    end
                    // If the master drops the request, abandon the wait.
                    if (~req) begin
                        state <= S_IDLE;
                    end
                end

                default: state <= S_IDLE;
            endcase
        end
    end

endmodule
