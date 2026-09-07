`timescale 1ns / 1ps

// =============================================================
// Furiosa TCP Style - Dot Product Engine (DPE)
// =============================================================
// TCP의 핵심: 컴파일러가 데이터 흐름을 재구성하여
// n차원 텐서 수축(Tensor Contraction)을 수행하는 유연한 연산 유닛
//
// 특징:
//   1. Feed Reuse - SRAM에서 읽은 데이터를 multiple times 전달
//   2. Configurable reshape - 컴파일러가 Wx4H, (2WxH)x2 등 설정
//   3. Temporal Pipelining - 시간 차원에서 데이터 재사용
//   4. Multicast Fetch Network - 하나의 데이터를 여러 Slice에 동시 전달
// =============================================================

module tcp_dpe #(
    parameter DATA_W   = 16,    // 입력 데이터 비폭 (INT8/INT16/BF16 등)
    parameter ACC_W    = 40,    // 누적기 비폭 (오버플로 방지)
    parameter NUM_DPE  = 8,     // Slice 내 DPE 수
    parameter FEED_NUM = 4      // 피드 재사용 횟수 (컴파일러 설정)
)(
    input  wire                  clk,
    input  wire                  rst_n,

    // --- Fetch Network Interface (컴파일러가 설정한 multicast 경로) ---
    input  wire                  fetch_valid,
    input  wire [DATA_W-1:0]     fetch_data_a,     // 텐서 A의 요소
    input  wire [DATA_W-1:0]     fetch_data_b,     // 텐서 B의 요소
    input  wire                  fetch_last,        // 현재 연산 마지막 데이터
    output wire                  fetch_ready,

    // --- 설정 레지스터 (컴파일러가 런타임에 설정) ---
    input  wire [15:0]           cfg_contract_dim, // 수축 축 크기 (K)
    input  wire [15:0]           cfg_tile_m,       // 타일 M 크기
    input  wire [15:0]           cfg_tile_n,       // 타일 N 크기
    input  wire [2:0]            cfg_data_fmt,     // 000=INT8, 001=INT16, 010=BF16

    // --- 출력 (누적 결과) ---
    output wire                  out_valid,
    output wire [ACC_W-1:0]      out_data,
    output wire                  out_last
);

    // -----------------------------------------------------------
    // Feed Reuse Counter
    // 컴파일러가 설정한 횟수만큼 같은 데이터를 재사용
    // 예: fetch_data_a를 4번 읽어서 각각 다른 B와 곱셈
    // -----------------------------------------------------------
    reg [3:0]  feed_cnt;
    reg        feed_active;
    reg [DATA_W-1:0] saved_a;
    reg [DATA_W-1:0] saved_b;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            feed_cnt    <= 0;
            feed_active <= 0;
            saved_a     <= 0;
            saved_b     <= 0;
        end else if (fetch_valid && fetch_ready) begin
            if (!feed_active) begin
                // 첫 번째 피드: 데이터 저장
                saved_a     <= fetch_data_a;
                saved_b     <= fetch_data_b;
                feed_active <= 1;
                feed_cnt    <= 1;
            end else if (feed_cnt < FEED_NUM - 1) begin
                // 재사용 중: 같은 데이터로 반복 연산
                feed_cnt <= feed_cnt + 1;
            end else begin
                // 재사용 완료
                feed_active <= 0;
                feed_cnt    <= 0;
            end
        end
    end

    // 재사용 중에는 저장된 데이터 사용
    wire [DATA_W-1:0] effective_a = feed_active ? saved_a : fetch_data_a;
    wire [DATA_W-1:0] effective_b = feed_active ? saved_b : fetch_data_b;
    wire              effective_v = fetch_valid || feed_active;

    // -----------------------------------------------------------
    // Multiply-Accumulate (TCP의 핵심 연산)
    // 단순히 dot product가 아니라, compiler가 지정한
    // reshape된 데이터 흐름에 따라 동작
    // -----------------------------------------------------------
    reg [ACC_W-1:0] accumulator;
    reg [15:0]      k_cnt;          // 수축 축 카운터
    reg             computing;
    reg             result_valid;

    // 곱셈 결과
    wire signed [ACC_W-1:0] product = $signed(effective_a) * $signed(effective_b);

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            accumulator  <= 0;
            k_cnt        <= 0;
            computing    <= 0;
            result_valid <= 0;
        end else if (effective_v && !computing) begin
            // 새로운 dot product 시작
            accumulator  <= product;
            k_cnt        <= 1;
            computing    <= 1;
            result_valid <= 0;
        end else if (computing && effective_v) begin
            if (k_cnt < cfg_contract_dim - 1) begin
                // 누적 중
                accumulator <= accumulator + product;
                k_cnt       <= k_cnt + 1;
            end else begin
                // dot product 완료
                accumulator  <= accumulator + product;
                result_valid <= 1;
                computing    <= 0;
                k_cnt        <= 0;
            end
        end else begin
            result_valid <= 0;
        end
    end

    assign fetch_ready = !computing || (k_cnt < cfg_contract_dim - 1);
    assign out_valid   = result_valid;
    assign out_data    = accumulator;
    assign out_last    = result_valid;

endmodule


// =============================================================
// 신호 흐름 다이어그램
// =============================================================
// Fetch Network(컴파일러 설정)         Config Registers(컴파일러 설정)
//      |    multicast data                 |
//      v                                    v
//  +---------------------------------------------+
//  |  Feed Reuse  ──>  multiplier  ──>  acc에 누적  |
//  |  (FEED_NUM)        (a*b)            (K축)    |
//  +---------------------------------------------+
//                                              |
//                                              v
//                                       out_valid / out_data
//                   (result_valid / accumulator)
// =============================================================


// =============================================================
// TCP Slice - Fetch Unit + DPE
// =============================================================
// 하나의 Slice = SRAM에서 데이터를 읽어 DPE에서 연산
// fetch network를 통해 다른 Slice와 데이터 multicast
// =============================================================

module tcp_slice #(
    parameter DATA_W = 16,
    parameter ACC_W  = 40,
    parameter NUM_DPE = 8
)(
    input  wire                  clk,
    input  wire                  rst_n,

    // --- SRAM Interface ---
    input  wire                  sram_read_valid,
    input  wire [DATA_W-1:0]     sram_read_data_a,
    input  wire [DATA_W-1:0]     sram_read_data_b,
    input  wire                  sram_read_last,

    // --- Fetch Network (다른 Slice로 multicast) ---
    input  wire                  net_in_valid,
    input  wire [DATA_W-1:0]     net_in_data_a,
    input  wire [DATA_W-1:0]     net_in_data_b,
    output wire                  net_out_valid,
    output wire [DATA_W-1:0]     net_out_data_a,
    output wire [DATA_W-1:0]     net_out_data_b,

    // --- 설정 (컴파일러가 런타임에 설정) ---
    input  wire [15:0]           cfg_contract_dim,
    input  wire [15:0]           cfg_tile_m,
    input  wire [15:0]           cfg_tile_n,
    input  wire [2:0]            cfg_data_fmt,

    // --- 출력 ---
    output wire                  out_valid,
    output wire [ACC_W-1:0]      out_data
);

    // Fetch Unit: SRAM 또는 네트워크에서 데이터 수집
    wire fetch_valid;
    wire [DATA_W-1:0] fetch_a, fetch_b;
    wire fetch_ready;

    assign fetch_valid = sram_read_valid || net_in_valid;
    assign fetch_a     = net_in_valid ? net_in_data_a : sram_read_data_a;
    assign fetch_b     = net_in_valid ? net_in_data_b : sram_read_data_b;

    // DPE: 실제 연산 수행
    tcp_dpe #(
        .DATA_W  (DATA_W),
        .ACC_W   (ACC_W),
        .NUM_DPE (NUM_DPE)
    ) u_dpe (
        .clk              (clk),
        .rst_n            (rst_n),
        .fetch_valid      (fetch_valid),
        .fetch_data_a     (fetch_a),
        .fetch_data_b     (fetch_b),
        .fetch_last       (1'b0),
        .fetch_ready      (fetch_ready),
        .cfg_contract_dim (cfg_contract_dim),
        .cfg_tile_m       (cfg_tile_m),
        .cfg_tile_n       (cfg_tile_n),
        .cfg_data_fmt     (cfg_data_fmt),
        .out_valid        (out_valid),
        .out_data         (out_data),
        .out_last         ()
    );

    // Multicast: 자신의 SRAM 데이터를 다른 Slice에도 전달
    assign net_out_valid   = sram_read_valid;
    assign net_out_data_a  = sram_read_data_a;
    assign net_out_data_b  = sram_read_data_b;

endmodule
