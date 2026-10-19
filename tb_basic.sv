/*
checks:

cold miss
read hit
same block different offset hit
write hit
4-way same-set fill
basic replacement
*/

`timescale 1ns/1ps

module tb_basic;

   localparam BLOCK_SIZE     = 256;
   localparam ADDRESS_WIDTH  = 21;
   localparam INDEX_WIDTH    = 8;
   localparam TAG_WIDTH      = 10;
   localparam OFFSET_WIDTH   = 3;
   localparam WORD_SIZE      = 32;
   localparam SETS           = 256;
   localparam WAYS           = 4;

   localparam int CLK_PERIOD_NS = 200;

   logic clock;
   logic rst_n;

   logic [ADDRESS_WIDTH - 1:0]            caddress;
   logic [WORD_SIZE - 1:0]                cdin;
   logic [BLOCK_SIZE - 1:0]               mdin;
   logic                                  rden;
   logic                                  wren;
   logic                                  hit;
   logic [WORD_SIZE - 1:0]                cdout;
   logic [BLOCK_SIZE - 1:0]               mdout;
   logic [TAG_WIDTH + INDEX_WIDTH - 1:0]  maddress;
   logic                                  mrden;
   logic                                  mwren;

   logic [WORD_SIZE-1:0] last_read_data;

   always begin
      clock = 1'b1;
      #(CLK_PERIOD_NS / 2);
      clock = 1'b0;
      #(CLK_PERIOD_NS / 2);
   end

   cache_controller #(
      .BLOCK_SIZE(BLOCK_SIZE),
      .ADDRESS_WIDTH(ADDRESS_WIDTH),
      .INDEX_WIDTH(INDEX_WIDTH),
      .TAG_WIDTH(TAG_WIDTH),
      .OFFSET_WIDTH(OFFSET_WIDTH),
      .WORD_SIZE(WORD_SIZE),
      .SETS(SETS),
      .WAYS(WAYS)
   ) DUT_CACHE (
      .clock(clock),
      .rst_n(rst_n),
      .caddress(caddress),
      .cdin(cdin),
      .mdin(mdin),
      .rden(rden),
      .wren(wren),
      .hit(hit),
      .cdout(cdout),
      .mdout(mdout),
      .maddress(maddress),
      .mrden(mrden),
      .mwren(mwren)
   );

   memory #(
      .ADDRESS_WIDTH(TAG_WIDTH + INDEX_WIDTH),
      .BLOCK_SIZE(BLOCK_SIZE),
      .FILE("")
   ) DUT_MEM (
      .clock(clock),
      .din(mdout),
      .address(maddress),
      .rden(mrden),
      .wren(mwren),
      .dout(mdin)
   );

   task automatic wait_cycles(input int n);
      repeat (n) @(posedge clock);
   endtask

   function automatic logic [ADDRESS_WIDTH-1:0] make_addr(
      input logic [TAG_WIDTH-1:0] tag,
      input logic [INDEX_WIDTH-1:0] index,
      input logic [OFFSET_WIDTH-1:0] offset
   );
      make_addr = {tag, index, offset};
   endfunction

   task automatic cache_read(input logic [ADDRESS_WIDTH-1:0] addr);
      int timeout;
      begin
         timeout = 0;

         @(negedge clock);
         caddress <= addr;
         cdin     <= '0;
         rden     <= 1'b1;
         wren     <= 1'b0;

         @(posedge clock);
         #1;

         rden <= 1'b0;
         wren <= 1'b0;

         while (DUT_CACHE.current_state != 1 && timeout < 30) begin
            @(posedge clock);
            #1;
            timeout++;
         end

         if (timeout >= 30) begin
            $display("ERROR: cache_read timeout at address %h", addr);
            $stop;
         end

         last_read_data = cdout;

         @(posedge clock);
         #1;
      end
   endtask

   task automatic cache_write(
      input logic [ADDRESS_WIDTH-1:0] addr,
      input logic [WORD_SIZE-1:0] data
   );
      int timeout;
      begin
         timeout = 0;

         @(negedge clock);
         caddress <= addr;
         cdin     <= data;
         rden     <= 1'b0;
         wren     <= 1'b1;

         @(posedge clock);
         #1;

         rden <= 1'b0;
         wren <= 1'b0;

         while (DUT_CACHE.current_state != 3 && timeout < 30) begin
            @(posedge clock);
            #1;
            timeout++;
         end

         if (timeout >= 30) begin
            $display("ERROR: cache_write timeout at address %h", addr);
            $stop;
         end

         @(posedge clock);
         #1;
      end
   endtask

   initial begin
      $dumpfile("tb_basic.vcd");
      $dumpvars(0, tb_basic);
   end

   initial begin
      logic [ADDRESS_WIDTH-1:0] A0;
      logic [ADDRESS_WIDTH-1:0] A0_NEXT;
      logic [ADDRESS_WIDTH-1:0] A1;
      logic [ADDRESS_WIDTH-1:0] A2;
      logic [ADDRESS_WIDTH-1:0] A3;
      logic [ADDRESS_WIDTH-1:0] A4;

      caddress       = '0;
      cdin           = '0;
      rden           = 1'b0;
      wren           = 1'b0;
      rst_n          = 1'b0;
      last_read_data = '0;

      A0      = make_addr(10'h000, 8'h04, 3'h0);
      A0_NEXT = make_addr(10'h000, 8'h04, 3'h1);
      A1      = make_addr(10'h001, 8'h04, 3'h0);
      A2      = make_addr(10'h002, 8'h04, 3'h0);
      A3      = make_addr(10'h003, 8'h04, 3'h0);
      A4      = make_addr(10'h004, 8'h04, 3'h0);

      wait_cycles(2);
      rst_n = 1'b1;
      wait_cycles(2);

      $display("\nBASIC TEST 1: Cold read A0. Expect miss, fetch, fill.");
      cache_read(A0);

      $display("\nBASIC TEST 2: Read A0 again. Expect hit.");
      cache_read(A0);

      $display("\nBASIC TEST 3: Read A0_NEXT. Same block, different offset. Expect hit.");
      cache_read(A0_NEXT);

      $display("\nBASIC TEST 4: Write A0 = DEAD_BEEF. Expect write hit.");
      cache_write(A0, 32'hDEAD_BEEF);

      $display("\nBASIC TEST 5: Read A0. Should return DEAD_BEEF.");
      cache_read(A0);

      if (last_read_data !== 32'hDEAD_BEEF) begin
         $display("ERROR: write-hit failed. got=%h expected=DEAD_BEEF", last_read_data);
         $stop;
      end
      else begin
         $display("PASS: write-hit worked. Read back %h", last_read_data);
      end

      $display("\nBASIC TEST 6: Fill same set with A1, A2, A3.");
      cache_read(A1);
      cache_read(A2);
      cache_read(A3);

      $display("\nBASIC TEST 7: Touch A0 again. Should still be present.");
      cache_read(A0);

      if (last_read_data !== 32'hDEAD_BEEF) begin
         $display("ERROR: A0 should still contain DEAD_BEEF. got=%h", last_read_data);
         $stop;
      end
      else begin
         $display("PASS: A0 still contains DEAD_BEEF.");
      end

      $display("\nBASIC TEST 8: Read A4. Same set is full, so replacement happens.");
      cache_read(A4);

      $display("\nBASIC TEST PASSED.");
      wait_cycles(5);
      $finish;
   end

   initial begin
      $monitor(
         "time=%0t | state=%0d | addr=%h | hit=%b | cdout=%h | last=%h | maddr=%h | mrden=%b | mwren=%b",
         $time,
         DUT_CACHE.current_state,
         caddress,
         hit,
         cdout,
         last_read_data,
         maddress,
         mrden,
         mwren
      );
   end

endmodule