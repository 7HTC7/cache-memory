`timescale 1ns/1ps

module cache_controller #(
    parameter BLOCK_SIZE = 256,
    parameter ADDRESS_WIDTH = 21,
    parameter INDEX_WIDTH = 8,
    parameter TAG_WIDTH = 10,
    parameter OFFSET_WIDTH = 3,
    parameter WORD_SIZE = 32,
    parameter NBLOCKS = 1024,
    parameter SETS = 256,
    parameter WAYS = 4
)
    (
        input logic                                  clock,
        input logic                                  rst_n,
        input logic [ADDRESS_WIDTH - 1:0]            caddress,
        input logic [WORD_SIZE - 1:0]                cdin,
        input logic [BLOCK_SIZE - 1:0]               mdin,
        input logic                                  rden,
        input logic                                  wren,
        output logic                                 hit,
        output logic [WORD_SIZE - 1:0]               cdout,
        output logic [BLOCK_SIZE - 1:0]              mdout,
        output logic [TAG_WIDTH + INDEX_WIDTH - 1:0] maddress,
        output logic                                 mrden,
        output logic                                 mwren
    );

    typedef enum logic [2:0] {
        STATE_IDLE,
        STATE_READ_HIT,
        STATE_READ_MISS,
        STATE_WRITE_HIT,
        STATE_WRITE_MISS,
        STATE_REPLACE,
        STATE_FETCH,
        STATE_FILL
    } state_t;

    state_t current_state, next_state;

    localparam TAG_MSB          = ADDRESS_WIDTH - 1;             // 20
    localparam TAG_LSB          = INDEX_WIDTH + OFFSET_WIDTH;     // 11
    localparam INDEX_MSB        = INDEX_WIDTH + OFFSET_WIDTH - 1; // 10
    localparam INDEX_LSB        = OFFSET_WIDTH;                   // 3
    localparam OFFSET_MSB       = OFFSET_WIDTH - 1;               // 2
    localparam OFFSET_LSB       = 0;

    logic cache_valid [0:SETS-1][0:WAYS-1];
    logic cache_dirty [0:SETS-1][0:WAYS-1];
    logic [TAG_WIDTH-1:0] cache_tag [0:SETS-1][0:WAYS-1];
    logic [BLOCK_SIZE-1:0] cache_mem [0:SETS-1][0:WAYS-1];

    // LRU rank:
    // 0 = most recently used
    // 3 = least recently used
    logic [1:0] cache_lru [0:SETS-1][0:WAYS-1];

    logic [ADDRESS_WIDTH - 1:0]   req_addr;
    logic                         req_read;
    logic                         req_write;
    logic [WORD_SIZE - 1:0]       req_wdata;

    logic [ADDRESS_WIDTH - 1:0]   active_addr;
    logic [INDEX_WIDTH - 1:0]     active_index;
    logic [TAG_WIDTH - 1:0]       active_tag;
    logic [OFFSET_WIDTH - 1:0]    active_offset;

    logic                         lookup_hit;
    logic [1:0]                   hit_way;
    logic [1:0]                   victim_way_comb;
    logic [1:0]                   victim_way_q;

    logic [WORD_SIZE - 1:0]       read_data;

    function automatic logic [WORD_SIZE - 1:0] block_get_word(
        input logic [BLOCK_SIZE - 1:0] block,
        input logic [OFFSET_WIDTH - 1:0] word_offset
    );
        return block[32 * word_offset +: WORD_SIZE];
    endfunction

    function automatic logic [BLOCK_SIZE - 1:0] block_set_word(
        input logic [BLOCK_SIZE - 1:0] block,
        input logic [OFFSET_WIDTH - 1:0] word_offset,
        input logic [WORD_SIZE - 1:0] word
    );
        logic [BLOCK_SIZE - 1:0] result;
        begin
            result = block;
            result[32 * word_offset +: WORD_SIZE] = word;
            return result;
        end
    endfunction

    assign active_addr = (current_state == STATE_IDLE) ? caddress : req_addr;
    assign active_index   = active_addr[INDEX_MSB:INDEX_LSB];
    assign active_tag     = active_addr[TAG_MSB:TAG_LSB];
    assign active_offset = active_addr[OFFSET_MSB:OFFSET_LSB];

    //hit lookup
    always_comb begin
        lookup_hit = 0;
        hit_way    = 0;

        for(int w=0; w<WAYS; w++) begin
            if(!lookup_hit && cache_valid[active_index][w] && cache_tag[active_index][w] == active_tag) begin
                lookup_hit = 1;
                hit_way    = w[1:0];
            end
        end
    end

    assign hit = lookup_hit; 

    assign read_data = block_get_word(cache_mem[active_index][hit_way], active_offset);

    // victim selection
    // prefer invalid line, otherwise choose LRU line

    always_comb begin
        victim_way_comb = 2'd0;

        // first search for invalid block
        for (int w = 0; w < WAYS; w++) begin
            if (!cache_valid[active_index][w]) begin
                victim_way_comb = w[1:0];
            end
        end

        // if all are valid, choose the line with LRU rank 3
        if (cache_valid[active_index][0] &&
            cache_valid[active_index][1] &&
            cache_valid[active_index][2] &&
            cache_valid[active_index][3]) begin

            for (int w = 0; w < WAYS; w++) begin
                if (cache_lru[active_index][w] == 2'd3) begin
                    victim_way_comb = w[1:0];
                end
            end
        end
    end

    //FSM combinational
    always_comb begin
        next_state = current_state;
        cdout    = '0;
        mdout    = '0;
        maddress = '0;
        mrden    = 1'b0;
        mwren    = 1'b0;

        case (current_state)
            STATE_IDLE: begin
                if (rden && lookup_hit)
                    next_state = STATE_READ_HIT;
                else if (rden)
                    next_state = STATE_READ_MISS;
                else if (wren && lookup_hit)
                    next_state = STATE_WRITE_HIT;
                else if (wren)
                    next_state = STATE_WRITE_MISS;
            end

            STATE_READ_HIT: begin
                cdout = read_data;
                next_state = STATE_IDLE;
            end

            STATE_READ_MISS: begin
                if (cache_valid[active_index][victim_way_q] &&
                    cache_dirty[active_index][victim_way_q]) begin
                    next_state = STATE_REPLACE;
                end
                else begin
                    next_state = STATE_FETCH;
                end
            end

            STATE_WRITE_MISS: begin
                if (cache_valid[active_index][victim_way_q] &&
                    cache_dirty[active_index][victim_way_q]) begin
                    next_state = STATE_REPLACE;
                end
                else begin
                    next_state = STATE_FETCH;
                end
            end

            STATE_REPLACE: begin //select which way to evict
                mwren    = 1'b1;
                maddress = {cache_tag[active_index][victim_way_q], active_index};
                mdout = cache_mem[active_index][victim_way_q];
                next_state = STATE_FETCH;
            end

            STATE_FETCH: begin
                mrden    = 1'b1;
                maddress = {active_tag, active_index};
                next_state = STATE_FILL;
            end

            STATE_FILL: begin
                if (req_read)
                    next_state = STATE_READ_HIT;
                else if (req_write)
                    next_state = STATE_WRITE_HIT;
                else
                    next_state = STATE_IDLE;
            end

            STATE_WRITE_HIT: begin
                next_state = STATE_IDLE;
            end

            default: begin
                next_state = STATE_IDLE;
            end
        endcase
    end

    //sequential logic
    always_ff @(posedge clock) begin
        if (!rst_n) begin
            current_state <= STATE_IDLE;
            req_addr      <= '0;
            req_read      <= 1'b0;
            req_write     <= 1'b0;
            req_wdata     <= '0;
            victim_way_q  <= 2'd0;

            for (int s = 0; s < SETS; s++) begin
                for (int w = 0; w < WAYS; w++) begin
                    cache_valid[s][w] <= 1'b0;
                    cache_dirty[s][w] <= 1'b0;
                    cache_tag[s][w]   <= '0;
                    cache_mem[s][w]   <= '0;
                    cache_lru[s][w]   <= w[1:0];
                end
            end
        end

        else begin
            current_state <= next_state;

            // latch request when CPU gives one in IDLE
            if (current_state == STATE_IDLE && (rden || wren)) begin
                req_addr     <= caddress;
                req_read     <= rden;
                req_write    <= wren;
                req_wdata    <= cdin;

                // on miss, latch victim way
                if (!lookup_hit) begin
                    victim_way_q <= victim_way_comb;
                end
            end

            // fill victim block from memory
            if (current_state == STATE_FILL) begin
                cache_mem[active_index][victim_way_q]   <= mdin;
                cache_tag[active_index][victim_way_q]   <= active_tag;
                cache_valid[active_index][victim_way_q] <= 1'b1;
                cache_dirty[active_index][victim_way_q] <= 1'b0;

                // update LRU: filled block becomes most recently used
                for (int w = 0; w < WAYS; w++) begin
                    if (w[1:0] != victim_way_q && cache_valid[active_index][w]) begin
                        if (cache_lru[active_index][w] != 2'd3) begin
                            cache_lru[active_index][w] <= cache_lru[active_index][w] + 2'd1;
                        end
                    end
                end

                cache_lru[active_index][victim_way_q] <= 2'd0;
            end

            // read hit: only update LRU
            if (current_state == STATE_READ_HIT) begin
                for (int w = 0; w < WAYS; w++) begin
                    if (w[1:0] != hit_way && cache_valid[active_index][w] && cache_lru[active_index][w] < cache_lru[active_index][hit_way]) begin
                        cache_lru[active_index][w] <= cache_lru[active_index][w] + 2'd1;
                    end
                end

                cache_lru[active_index][hit_way] <= 2'd0;
            end

            // write hit: update word, dirty bit and LRU
            if (current_state == STATE_WRITE_HIT) begin
                cache_mem[active_index][hit_way] <= block_set_word(
                    cache_mem[active_index][hit_way],
                    active_offset,
                    req_wdata
                );

                cache_dirty[active_index][hit_way] <= 1'b1;

                for (int w = 0; w < WAYS; w++) begin
                    if (w[1:0] != hit_way && cache_valid[active_index][w] && cache_lru[active_index][w] < cache_lru[active_index][hit_way]) begin
                        cache_lru[active_index][w] <= cache_lru[active_index][w] + 2'd1;
                    end
                end
\
                cache_lru[active_index][hit_way] <= 2'd0;
            end
        end
    end

endmodule