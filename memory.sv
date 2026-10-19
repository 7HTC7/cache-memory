`timescale 1ns/1ps

module memory
#(
    parameter ADDRESS_WIDTH = 18,
    parameter BLOCK_SIZE    = 256,
    parameter FILE          = ""
)
(
    input  logic clock,
    input  logic [BLOCK_SIZE - 1:0] din,
    input  logic [ADDRESS_WIDTH - 1:0] address,
    input  logic rden,
    input  logic wren,
    output logic [BLOCK_SIZE - 1:0] dout
);

    localparam DEPTH = 2**ADDRESS_WIDTH; //MM=2^18 blocks

    reg [BLOCK_SIZE-1:0] mem [0:DEPTH-1];

    integer i;

    initial begin
        if (FILE != "") begin
            $readmemh(FILE, mem);
        end
        else begin
            for (i=0; i<DEPTH; i=i+1) begin
                mem[i] = {BLOCK_SIZE{1'b0}};
            end
        end
    end

    always @(posedge clock) begin
        if (wren) begin
            mem[address] <= din;
        end
    end

    always @(posedge clock) begin
        if (rden) begin
            dout <= mem[address];
        end
    end

endmodule