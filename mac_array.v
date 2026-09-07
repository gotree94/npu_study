`timescale 1ns / 1ps

// =============================================================
// DeepX Style - MAC Array (Multiply-Accumulate Array)
// =============================================================
// 전통적인 2D 행렬곱 가속기 구조
// - 고정된 크기의 MAC 셀 배열 (예: 8x8, 16x16)
// - Systolic Array 또는 직접 연결 구조
// - 데이터가 배열을 통과하며 누적
//
// TCP와의 차이점:
//   TCP: 컴파일러가 데이터 흐름을 재구성, n차원 텐서 직접 처리
//       리소스를 런타임에 reshape 가능, feed reuse (시간 재사용)
//   MAC Array: 고정된 2D 그리드, 데이터가 미리 정해진 경로로만 이동
//       MxN 고정 연산, 벡터 재사용성 낮음, 비대칭 텐서 비효율
// =============================================================

module mac_cell #(
    parameter DATA_W = 16,
    parameter ACC_W  = 40
)(
    input  wire                clk,
    input  wire                rst_n,
    input  wire                en,          // 이 셀 활성화
    input  wire [DATA_W-1:0]   a_in,        // 来自 위쪽/왼쪽 데이터
    input  wire [DATA_W-1:0]   b_in,
    input  wire [ACC_W-1:0]    acc_in,      // 이전 누적값
    output reg  [ACC_W-1:0]    acc_out,     // 누적 결과
    output reg  [DATA_W-1:0]   a_out,       // 다음 셀로 전달
    output reg  [DATA_W-1:0]   b_out
);

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            acc_out <= 0;
            a_out   <= 0;
            b_out   <= 0;
        end else if (en) begin
            // MAC: acc_out = acc_in + a * b
            acc_out <= acc_in + ($signed(a_in) * $signed(b_in));
            a_out   <= a_in;
            b_out   <= b_in;
        end
    end

endmodule


// =============================================================
// MAC Array - 고정 크기 2D 그리드
// =============================================================
// 8x8 MAC 셀: 64개의 MAC 셀을 병렬 배치
// - 행(i)으로 텐서 A의 M축이 흐르고, 열(j)로 텐서 B의 N축 흐름
// - 각 (i,j) 셀이 C[i,j] = Σ_k A[i,k]*B[k,j]을 계산
// - 모든 셀이 같은 K만큼 누적 후 결과 출력
// =============================================================

module mac_array #(
    parameter DATA_W = 16,
    parameter ACC_W  = 40,
    parameter M_SIZE = 8,       // 행 크기 (고정!)
    parameter N_SIZE = 8        // 열 크기 (고정!)
)(
    input  wire                clk,
    input  wire                rst_n,
    input  wire                valid_in,

    // --- 텐서 A: M x K, 각 행렬이 세로로 흐름 ---
    input  wire [M_SIZE-1:0][DATA_W-1:0] a_rows,   // M행 입력 (한 K열씩)

    // --- 텐서 B: K x N, 각 열이 가로로 흐름 ---
    input  wire [N_SIZE-1:0][DATA_W-1:0] b_cols,   // N열 입력

    // --- 수축 축 크기 (K) ---
    input  wire [15:0]         contract_dim,

    // --- 출력: M x N 결과 ---
    output reg  [M_SIZE-1:0][N_SIZE-1:0][ACC_W-1:0] c_matrix,
    output reg  result_valid
);

    // 내부 MAC 셀 배열: (M x N) 셀
    wire [M_SIZE-1:0][N_SIZE-1:0][ACC_W-1:0] acc_chain;
    wire [M_SIZE-1:0][N_SIZE-1:0][DATA_W-1:0] a_chain;
    wire [M_SIZE-1:0][N_SIZE-1:0][DATA_W-1:0] b_chain;

    // K 축 카운터 - 고정 그리드에서 누적 회수 결정
    reg [15:0] k_cnt;
    reg        computing;
    reg        capture;

    genvar i, j;
    generate
        for (i = 0; i < M_SIZE; i = i + 1) begin : rows
            for (j = 0; j < N_SIZE; j = j + 1) begin : cols
                mac_cell #(
                    .DATA_W (DATA_W),
                    .ACC_W  (ACC_W)
                ) u_mac (
                    .clk    (clk),
                    .rst_n  (rst_n),
                    .en     (valid_in),
                    .a_in   (i == 0 ? a_rows[j]                        : a_chain[i-1][j]),
                    .b_in   (j == 0 ? b_cols[i]                        : b_chain[i][j-1]),
                    .acc_in ((computing && k_cnt > 0) ? acc_chain[i][j] : {ACC_W{1'b0}}),
                    .acc_out(acc_chain[i][j]),
                    .a_out  (a_chain[i][j]),
                    .b_out  (b_chain[i][j])
                );
            end
        end
    endgenerate

    // -----------------------------------------------------------
    // K 축 누적 제어
    // 고정 그리드에서는 모든 셀이 동일한 K만큼 누적
    // (TCP와 달리 셀마다 다른 K 길이 불가능)
    // -----------------------------------------------------------
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            k_cnt        <= 0;
            computing    <= 0;
            capture      <= 0;
            result_valid <= 0;
        end else if (valid_in && !computing) begin
            computing <= 1;
            k_cnt     <= 1;
            result_valid <= 0;
        end else if (computing) begin
            if (k_cnt < contract_dim - 1) begin
                k_cnt <= k_cnt + 1;
            end else begin
                // 누적 완료 - 결과 캡처
                capture   <= 1;
                computing <= 0;
                k_cnt     <= 0;
            end
        end else if (capture) begin
            c_matrix     <= acc_chain;
            capture      <= 0;
            result_valid <= 1;
        end else begin
            result_valid <= 0;
        end
    end

endmodule


// =============================================================
// 심플 테스트벤치 (두 방식 비교용)
// =============================================================
// A(2x2) x B(2x2) = C(2x2)
// A = [1 2]   B = [5 6]   C = [19 22]
//     [3 4]       [7 8]       [43 50]
// =============================================================
module tb_mac_array;

    reg clk, rst_n, valid_in;
    reg [15:0] contract_dim;

    // 8x8 배열에서 2x2 부분만 사용 (나머지는 0)
    reg [7:0][15:0] a_rows_init;
    reg [7:0][15:0] b_cols_init;

    wire [7:0][7:0][39:0] c_matrix;
    wire result_valid;

    mac_array #(
        .DATA_W (16),
        .ACC_W  (40),
        .M_SIZE (8),
        .N_SIZE (8)
    ) uut (
        .clk          (clk),
        .rst_n        (rst_n),
        .valid_in     (valid_in),
        .a_rows       (a_rows_init),
        .b_cols       (b_cols_init),
        .contract_dim (contract_dim),
        .c_matrix     (c_matrix),
        .result_valid (result_valid)
    );

    always #5 clk = ~clk;

    initial begin
        clk = 0; rst_n = 0; valid_in = 0; contract_dim = 2;
        a_rows_init = 0; b_cols_init = 0;

        // A 행렬 (M=2 x K=2): a_rows[m] = A[m][k]
        a_rows_init[0] = 16'd1;  // A[0][0]
        a_rows_init[1] = 16'd2;  // A[0][1]
        a_rows_init[2] = 16'd3;  // A[1][0]
        a_rows_init[3] = 16'd4;  // A[1][1]

        // B 행렬 (K=2 x N=2): b_cols[n] = B[k][n]
        b_cols_init[0] = 16'd5;  // B[0][0]
        b_cols_init[1] = 16'd7;  // B[1][0]
        b_cols_init[2] = 16'd6;  // B[0][1]
        b_cols_init[3] = 16'd8;  // B[1][1]

        #20 rst_n = 1;
        #10 valid_in = 1;
        #10 valid_in = 0;

        wait (result_valid);
        // 검증: C[0][0] = 1*5 + 2*7 = 19
        #20;
        $display("C[0][0] = %0d (기대값 19)", c_matrix[0][0]);
        $display("C[0][1] = %0d (기대값 22)", c_matrix[0][1]);
        $display("C[1][0] = %0d (기대값 43)", c_matrix[1][0]);
        $display("C[1][1] = %0d (기대값 50)", c_matrix[1][1]);
        $finish;
    end

endmodule
