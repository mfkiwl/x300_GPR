//
// Copyright 2016 Ettus Research
//
// radar_core
//   Contains Waveform generator and radar pulse controller
//
// Note: Register addresses defined radio_core_regs.vh

module radar_core #(
  parameter RADIO_NUM = 0,
  parameter USE_SPI_CLK = 0  // Drive SPI core with input spi_clk. WARNING: This adds a clock crossing FIFO!
)(
  input clk, input reset,
  input clear_rx, input clear_tx,
  input [15:0] src_sid,             // Source stream ID of this block
  input [15:0] dst_sid,             // Destination stream ID destination of downstream block
  input [15:0] rx_resp_dst_sid,     // Destination stream ID for TX errors / response packets (i.e. host PC)
  input [15:0] tx_resp_dst_sid,     // Destination stream ID for TX errors / response packets (i.e. host PC)
  // Interface to the physical radio (ADC, DAC, controls)
  input [31:0] rx, input rx_stb,
  output [31:0] tx, input tx_stb,
  // VITA time
  input [63:0] vita_time, input [63:0] vita_time_lastpps,
  // Interfaces to front panel and daughter board
  input pps,
  input [31:0] misc_ins, output [31:0] misc_outs,
  input [31:0] fp_gpio_in, output [31:0] fp_gpio_out, output [31:0] fp_gpio_ddr,
  input [31:0] db_gpio_in, output [31:0] db_gpio_out, output [31:0] db_gpio_ddr,
  output [31:0] leds,
  input spi_clk, input spi_rst, output [7:0] sen, output sclk, output mosi, input miso,

  // Interface to the NoC Shell
  input set_stb, input [7:0] set_addr, input [31:0] set_data,
  output reg rb_stb, input [7:0] rb_addr, output reg [63:0] rb_data,
  input [31:0] tx_tdata, input tx_tlast, input tx_tvalid, output tx_tready, input [127:0] tx_tuser,
  output [31:0] rx_tdata, output rx_tlast, output rx_tvalid, input rx_tready, output [127:0] rx_tuser,
  output [63:0] resp_tdata, output resp_tlast, output resp_tvalid, input resp_tready
);


  `include "radar_core_regs.vh"

  /********************************************************
  ** Settings Bus / Readback Registers
  ********************************************************/
  wire        loopback;
  wire [31:0] test_readback;
  wire db_rb_stb;
  wire [63:0] db_rb_data;
  always @(*) begin
    case (rb_addr)
      RB_VITA_TIME    : {rb_stb, rb_data} <= {db_rb_stb, vita_time};
      RB_VITA_LASTPPS : {rb_stb, rb_data} <= {db_rb_stb, vita_time_lastpps};
      RB_TEST         : {rb_stb, rb_data} <= {db_rb_stb, {rx, test_readback}};
      RB_TXRX         : {rb_stb, rb_data} <= {db_rb_stb, {tx, rx}};
      RB_RADIO_NUM    : {rb_stb, rb_data} <= {db_rb_stb, {32'd0, RADIO_NUM[31:0]}};
      // All others default to daughter board control readback data
      default         : {rb_stb, rb_data} <= {db_rb_stb, db_rb_data};
    endcase
  end

  // Set this register to loop TX data directly to RX data.
  setting_reg #(.my_addr(SR_LOOPBACK), .width(1)) sr_loopback (
    .clk(clk), .rst(reset), .strobe(set_stb), .addr(set_addr), .in(set_data),
    .out(loopback), .changed());

  // Set this register to put a test value on the readback mux.
  setting_reg #(.my_addr(SR_TEST), .width(32)) sr_test (
    .clk(clk), .rst(reset), .strobe(set_stb), .addr(set_addr), .in(set_data),
    .out(test_readback), .changed());

  /********************************************************
  ** Daughter board control
  ********************************************************/
  db_control #(
    .USE_SPI_CLK(USE_SPI_CLK))
  db_control (
    .clk(clk), .reset(reset),
    .set_stb(set_stb), .set_addr(set_addr), .set_data(set_data),
    .rb_stb(db_rb_stb), .rb_addr(rb_addr), .rb_data(db_rb_data),
    .run_rx(run_rx), .run_tx(run_tx),
    .misc_ins(misc_ins), .misc_outs(misc_outs),
    .fp_gpio_in(fp_gpio_in), .fp_gpio_out(fp_gpio_out), .fp_gpio_ddr(fp_gpio_ddr),
    .db_gpio_in(db_gpio_in), .db_gpio_out(db_gpio_out), .db_gpio_ddr(db_gpio_ddr),
    .leds(leds),
    .spi_clk(spi_clk), .spi_rst(spi_rst), .sen(sen), .sclk(sclk), .mosi(mosi), .miso(miso));

    /********************************************************
    ** Waveform Generator and Radar Control Blocks
    ********************************************************/

  localparam CHIRP_CLK_FREQ = 245760000;    // Hz
  localparam ADC_SAMPLE_COUNT_INIT = 32'h000001fe;
  localparam CHIRP_PRF_INT_COUNT_INIT = 32'h00000000;
  localparam CHIRP_PRF_FRAC_COUNT_INIT = 32'h1d4c0000;
  localparam CHIRP_TUNING_COEF_INIT = 32'b1;
  localparam CHIRP_COUNT_MAX_INIT = 32'h00000dff; // 3584 samples
  localparam CHIRP_FREQ_OFFSET_INIT = 32'h0b00; // 2816 -> 10.56 MHz min freq
  localparam CHIRP_CTRL_WORD_INIT = 32'h10;

  wire awg_ready;
  wire awg_done;
  wire awg_active;
  wire awg_init;
  wire awg_enable;
  wire adc_enable;

  wire [31:0] chirp_control_word;

  setting_reg #(.my_addr(SR_CH_CTRL_WORD_ADDR), .at_reset(CHIRP_CTRL_WORD_INIT)) sr_ch_ctrl_word (
    .clk(clk),.rst(rst),.strobe(set_stb),.addr(set_addr),
    .in(set_data),.out(chirp_control_word),.changed());

  radar_pulse_controller #(
      .CLK_FREQ (CHIRP_CLK_FREQ),
      .ADC_SAMPLE_COUNT_INIT(ADC_SAMPLE_COUNT_INIT),
      .CHIRP_PRF_INT_COUNT_INIT(CHIRP_PRF_INT_COUNT_INIT),
      .CHIRP_PRF_FRAC_COUNT_INIT(CHIRP_PRF_FRAC_COUNT_INIT),

      .SR_PRF_INT_ADDR(SR_PRF_INT_ADDR),
      .SR_PRF_FRAC_ADDR(SR_PRF_FRAC_ADDR),
      .SR_ADC_SAMPLE_ADDR(SR_ADC_SAMPLE_ADDR)
  )
  radar_pulse_controller_inst (
    //.aclk(sysclk_bufg),
    //.aresetn(sysclk_resetn),
    .clk(clk),
    .reset(reset),
    .set_stb(set_stb), .set_addr(set_addr), .set_data(set_data),

    .awg_ready (awg_ready),
    .awg_done (awg_done),
    .awg_active (awg_active),
    .awg_init  (awg_init),
    .awg_enable  (awg_enable),
    .adc_enable   (adc_enable)
  );

  wire [15:0] awg_out_i;
  wire [15:0] awg_out_q;
  wire awg_data_valid;
  wire [31:0] awg_data_len;         // payload len in samples
  wire [127:0] awg_data_tuser;

  wire run_awg;
  wire [31:0] sample_awg;
  wavegen_block #(
      .CHIRP_TUNING_COEF_INIT(CHIRP_TUNING_COEF_INIT),
      .CHIRP_COUNT_MAX_INIT (CHIRP_COUNT_MAX_INIT),
      .CHIRP_FREQ_OFFSET_INIT (CHIRP_FREQ_OFFSET_INIT),


      .SR_CH_COUNTER_ADDR(SR_CH_COUNTER_ADDR),
      .SR_CH_TUNING_COEF_ADDR(SR_CH_TUNING_COEF_ADDR),
      .SR_CH_FREQ_OFFSET_ADDR(SR_CH_FREQ_OFFSET_ADDR)
  )
  wavegen_block_inst (
      .clk(clk),
      .rst(reset),

      .awg_out_i(awg_out_i),
      .awg_out_q(awg_out_q),
      .awg_data_valid(awg_data_valid),
      .awg_data_len(awg_data_len),

      .set_stb(set_stb), .set_addr(set_addr), .set_data(set_data),

      .wr_axis_tdata(tx_tdata),
      .wr_axis_tvalid(tx_tvalid),
      .wr_axis_tlast(tx_tlast),
      .wr_axis_tuser(),
      .wr_axis_tkeep(),
      .wr_axis_tdest(),
      .wr_axis_tid(),
      .wr_axis_tready(tx_tready),

      .chirp_control_word(chirp_control_word),


      .awg_ready (awg_ready),
      .awg_done (awg_done),
      .awg_active (awg_active),
      .awg_init  (awg_init),
      .awg_enable  (awg_enable),
      .adc_enable   (adc_enable)

 );
 cvita_hdr_encoder cvita_hdr_encoder (
   .pkt_type(2'd0), .eob(1'b1), .has_time(1'b0),
   .seqnum(12'd0), .payload_length({awg_data_len[14:0],2'b00}), .dst_sid(dst_sid), .src_sid(src_sid),
   .vita_time(vita_time),
   .header(awg_data_tuser));


 assign run_awg = ~(strobe & ~awg_data_valid);
 assign sample_awg = {awg_out_i,awg_out_q};
  /********************************************************
  ** TX Chain
  ********************************************************/
  wire [31:0] tx_idle;
  setting_reg #(.my_addr(SR_CODEC_IDLE), .awidth(8), .width(32), .at_reset(0)) sr_codec_idle (
    .clk(clk), .rst(reset), .strobe(set_stb), .addr(set_addr), .in(set_data),
    .out(tx_idle), .changed());

  wire [31:0] sample_tx;
  wire [63:0] txresp_tdata;
  wire [127:0] txresp_tuser;
  wire txresp_tlast, txresp_tvalid, txresp_tready;
  // tx_control_gen3 #(.SR_ERROR_POLICY(SR_TX_CTRL_ERROR_POLICY)) tx_control_gen3 (
  //   .clk(clk), .reset(reset), .clear(clear_tx),
  //   .set_stb(set_stb), .set_addr(set_addr), .set_data(set_data),
  //   .vita_time(vita_time), .resp_sid({src_sid, tx_resp_dst_sid}),
  //   .tx_tdata(tx_tdata), .tx_tlast(tx_tlast), .tx_tvalid(tx_tvalid), .tx_tready(tx_tready), .tx_tuser(tx_tuser),
  //   .resp_tdata(txresp_tdata), .resp_tlast(txresp_tlast), .resp_tvalid(txresp_tvalid), .resp_tready(txresp_tready), .resp_tuser(txresp_tuser),
  //   .run(run_tx), .sample(sample_tx), .strobe(tx_stb));

 // assign tx = run_tx ? sample_tx : tx_idle;

 assign tx = run_awg ? sample_awg : tx_idle;

 assign txresp_tdata = 'b0;
 assign txresp_tuser = 'b0;
 assign txresp_tlast = 0;
 assign txresp_tvalid = 0;


 localparam ADC_AXI_DATA_WIDTH = 64;
 localparam ADC_AXI_TID_WIDTH = 1;
 localparam ADC_AXI_TDEST_WIDTH = 1;
 localparam ADC_AXI_TUSER_WIDTH = 1;
 localparam ADC_AXI_STREAM_ID = 1'b0;
 localparam ADC_AXI_STREAM_DEST = 1'b0;

 localparam PK_AXI_DATA_WIDTH = 512;
 localparam PK_AXI_TID_WIDTH = 1;
 localparam PK_AXI_TDEST_WIDTH = 1;
 localparam PK_AXI_TUSER_WIDTH = 1;
 localparam PK_AXI_STREAM_ID = 1'b0;
 localparam PK_AXI_STREAM_DEST = 1'b0;

 localparam SIMULATION = 0;
 localparam FFT_LEN = 4096;//32768

 localparam FCUTOFF_IND = FFT_LEN/2;

 wire [ADC_AXI_DATA_WIDTH-1:0]     axis_adc_tdata;
 wire axis_adc_tvalid;
 wire axis_adc_tlast;
 wire [ADC_AXI_DATA_WIDTH/8-1:0]   axis_adc_tkeep;
 wire [ADC_AXI_DATA_WIDTH/8-1:0]   axis_adc_tstrb;
 wire [ADC_AXI_TID_WIDTH-1:0] axis_adc_tid;
 wire [ADC_AXI_TDEST_WIDTH-1:0] axis_adc_tdest;
 wire [ADC_AXI_TUSER_WIDTH-1:0] axis_adc_tuser;
 wire axis_adc_tready;

 wire [63:0] iq_tdata;
 wire iq_tvalid;
 wire iq_tlast;
 wire iq_tready;
 wire iq_first;
 wire [63:0] counter_id;


 radar_sample_synchronizer #(
     .ADC_AXI_DATA_WIDTH(ADC_AXI_DATA_WIDTH),
     .ADC_AXI_TID_WIDTH(ADC_AXI_TID_WIDTH),
     .ADC_AXI_TDEST_WIDTH(ADC_AXI_TDEST_WIDTH),
     .ADC_AXI_TUSER_WIDTH(ADC_AXI_TUSER_WIDTH),
     .ADC_AXI_STREAM_ID(ADC_AXI_STREAM_ID),
     .ADC_AXI_STREAM_DEST(ADC_AXI_STREAM_DEST),
     .PK_AXI_DATA_WIDTH(PK_AXI_DATA_WIDTH),
     .PK_AXI_TID_WIDTH(PK_AXI_TID_WIDTH),
     .PK_AXI_TDEST_WIDTH(PK_AXI_TDEST_WIDTH),
     .PK_AXI_TUSER_WIDTH(PK_AXI_TUSER_WIDTH),
     .PK_AXI_STREAM_ID(PK_AXI_STREAM_ID),
     .PK_AXI_STREAM_DEST(PK_AXI_STREAM_DEST)
 )
 radar_sample_synchronizer (
     .clk (clk), // AXI input clock
     .reset (reset), // Active low AXI reset signal

     // --ADC Data Out Signals
    .iq_tdata(iq_tdata),
    .iq_tvalid(iq_tvalid),
    .iq_tlast(iq_tlast),
    .iq_tready(iq_tready),
    .iq_first(iq_first),
    .counter_id(),

    .adc_data_iq(rx),
    .dac_data_iq(tx),
    .adc_data_valid(rx_stb),


    .axis_adc_tdata                      (axis_adc_tdata),
    .axis_adc_tvalid                     (axis_adc_tvalid),
    .axis_adc_tlast                      (axis_adc_tlast),
    .axis_adc_tkeep                      (axis_adc_tkeep),
    .axis_adc_tid                        (axis_adc_tid),
    .axis_adc_tdest                      (axis_adc_tdest),
    .axis_adc_tuser                      (axis_adc_tuser),
    .axis_adc_tready                     (axis_adc_tready),
    .axis_adc_tstrb                      (axis_adc_tstrb),

    .chirp_control_word(chirp_control_word),
    .awg_init(awg_init),
    .awg_enable(awg_enable),
    .adc_enable(adc_enable)

  );

  // --ADC AXI-Stream Data Out Signals from fmc150_dac_adc module
 wire [PK_AXI_DATA_WIDTH-1:0]   axis_pk_tdata;
 wire                            axis_pk_tvalid;
 wire                            axis_pk_tlast;
 wire [PK_AXI_DATA_WIDTH/8-1:0] axis_pk_tkeep;
 wire [PK_AXI_TID_WIDTH-1:0]    axis_pk_tid;
 wire [PK_AXI_TDEST_WIDTH-1:0]  axis_pk_tdest;
 wire [PK_AXI_TUSER_WIDTH-1:0]  axis_pk_tuser;
 wire                            axis_pk_tready;
 wire [PK_AXI_DATA_WIDTH/8-1:0] axis_pk_tstrb;

  wire [31:0] lpf_cutoff_ind;
  wire[7:0] threshold_ctrl_i;
  wire[7:0] threshold_ctrl_q;

  assign lpf_cutoff_ind = FCUTOFF_IND;
  assign threshold_ctrl_i = {4'hf,4'h1};
  assign threshold_ctrl_q = {4'hf,4'h1};

  matched_filter_range_detector #(
       .PK_AXI_DATA_WIDTH(PK_AXI_DATA_WIDTH),
       .PK_AXI_TID_WIDTH (PK_AXI_TID_WIDTH),
       .PK_AXI_TDEST_WIDTH(PK_AXI_TDEST_WIDTH),
       .PK_AXI_TUSER_WIDTH(PK_AXI_TUSER_WIDTH),
       .PK_AXI_STREAM_ID (PK_AXI_STREAM_ID),
       .PK_AXI_STREAM_DEST (PK_AXI_STREAM_DEST),
       .FFT_LEN(FFT_LEN),
       .SIMULATION(SIMULATION)

)
matched_filter_range_detector_inst(

     .aclk(clk), // AXI input clock
     .aresetn(~reset), // Active low AXI reset signal

     // --ADC Data Out Signals
    .adc_iq_tdata(iq_tdata[31:0]),
    .dac_iq_tdata(iq_tdata[63:32]),
    .iq_tvalid(iq_tvalid),
    .iq_tlast(iq_tlast),
    .iq_tready(iq_tready),
    .iq_first(iq_first),
    .counter_id(vita_time),

    .pk_axis_tdata(axis_pk_tdata),
    .pk_axis_tvalid(axis_pk_tvalid),
    .pk_axis_tlast(axis_pk_tlast),
    .pk_axis_tkeep(axis_pk_tkeep),
    .pk_axis_tdest(axis_pk_tdest),
    .pk_axis_tid(axis_pk_tid),
    .pk_axis_tstrb(axis_pk_tstrb),
    .pk_axis_tuser(axis_pk_tuser),
    .pk_axis_tready(axis_pk_tready),

    .lpf_cutoff(lpf_cutoff_ind),
    .threshold_ctrl(threshold_ctrl_i),    // {4b word index, 4b word value} in 64bit threshold
   // .threshold_ctrl_q(threshold_ctrl_q),    // {4b word index, 4b word value} in 64bit threshold

  // Control Module signals
   .chirp_ready                         (awg_ready),
   .chirp_done                          (awg_done),
   .chirp_active                        (awg_active),
   .chirp_init                          (awg_init),
   .chirp_enable                        (awg_enable),
   .chirp_enable                        (adc_enable),
   .chirp_control_word          (chirp_control_word),
   .chirp_freq_offset           (chirp_freq_offset),
   .chirp_tuning_word_coeff     (chirp_tuning_word_coeff),
   .chirp_count_max             (chirp_count_max)

     );


  /********************************************************
  ** RX Chain
  ********************************************************/
  wire [31:0] sample_rx     = loopback ? tx     : rx;     // Digital Loopback TX -> RX
  wire        sample_rx_stb = loopback ? tx_stb : rx_stb;

  wire [63:0] rxresp_tdata;
  wire [127:0] rxresp_tuser;
  wire rxresp_tlast, rxresp_tvalid, rxresp_tready;
  rx_control_gen3 #(
    .SR_RX_CTRL_COMMAND(SR_RX_CTRL_COMMAND),
    .SR_RX_CTRL_TIME_HI(SR_RX_CTRL_TIME_HI),
    .SR_RX_CTRL_TIME_LO(SR_RX_CTRL_TIME_LO),
    .SR_RX_CTRL_HALT(SR_RX_CTRL_HALT),
    .SR_RX_CTRL_MAXLEN(SR_RX_CTRL_MAXLEN),
    .SR_RX_CTRL_CLEAR_CMDS(SR_RX_CTRL_CLEAR_CMDS),
    .SR_RX_CTRL_OUTPUT_FORMAT(SR_RX_CTRL_OUTPUT_FORMAT)
  )
  rx_control_gen3 (
    .clk(clk), .reset(reset), .clear(clear_rx),
    .vita_time(vita_time), .sid({src_sid, dst_sid}), .resp_sid({src_sid, rx_resp_dst_sid}),
    .set_stb(set_stb), .set_addr(set_addr), .set_data(set_data),
    .rx_tdata(rx_tdata), .rx_tlast(rx_tlast), .rx_tvalid(rx_tvalid), .rx_tready(rx_tready), .rx_tuser(rx_tuser),
    .resp_tdata(rxresp_tdata), .resp_tlast(rxresp_tlast), .resp_tvalid(rxresp_tvalid), .resp_tready(rxresp_tready), .resp_tuser(rxresp_tuser),
    .strobe(sample_rx_stb), .sample(sample_rx), .run(run_rx));

  // Generate error response packets from TX & RX control
  axi_packet_mux #(.NUM_INPUTS(2), .FIFO_SIZE(5)) axi_packet_mux (
    .clk(clk), .reset(reset), .clear(1'b0),
    .i_tdata({txresp_tdata, rxresp_tdata}), .i_tlast({txresp_tlast, rxresp_tlast}),
    .i_tvalid({txresp_tvalid, rxresp_tvalid}), .i_tready({txresp_tready, rxresp_tready}), .i_tuser({txresp_tuser, rxresp_tuser}),
    .o_tdata(resp_tdata), .o_tlast(resp_tlast), .o_tvalid(resp_tvalid), .o_tready(resp_tready));

endmodule