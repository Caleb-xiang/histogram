module histogram1(
    input rst_n,

    input cam_clk,
    input cam_vsync,
    input cam_href,
    input cam_valid,
    input [7:0] cam_gray,

    output post_frame_vsync,
    output post_frame_href,
    output post_frame_clken,
    output [7:0] post_img_Y,

    input vga_clk,
    input vga_rd_en,
    input [7:0] vga_rd_addr,
    output [18:0] vga_rd_data
);

wire [18:0] wr_data;
wire [18:0] rd_data;
reg wr_en;
reg vsync_delay;

reg [7:0] ram_addr_b;
reg ram_rd_b;
wire [18:0] ram_rd_q_b;

reg ram_wr_b;

reg ram_vga_wr;
reg [7:0] ram_vga_wraddr;
reg [18:0] ram_vga_data;

///main code
//当摄像头输入的灰度数据有效时，会先进行读RAM操作，然后将读出的数据加1后，再次写入相同地址
//读操作需要一个时钟周期，因此“写使能”直接将输入的Valid信号延迟一个时钟周期即可
always @(posedge cam_clk or negedge rst_n) begin
    if (!rst_n)
        wr_en <= 1'b0;
    else
        wr_en <= cam_valid;
end

//双端口RAM，用于统计一帧图像的灰度直方图
ram_2port u_ram_2port(
    //端口A：摄像头输出的灰度数据作为RAM地址，先将该地址中的数据读出来，加1后再写入RAM1中
    .clock_a ( cam_clk ),
    .aclr_a ( !rst_n ),
    .rden_a ( cam_valid ), // 读端口A
    .address_a ( cam_gray ),
    .q_a ( rd_data ),
    .wren_a ( wr_en ), // 写端口A
    .data_a ( rd_data+1 ), // 直方图统计过程中，写入RAM的数据为（当前地址的数据+1）

    //端口B：一帧结束后读出RAM中的数据进行寄存，下一帧开始前将RAM初始化为0
    .clock_b ( vga_clk ),
    .aclr_b ( 1'b0 ),
    .rden_b ( ram_rd_b ), // 读端口B
    .address_b ( ram_addr_b ),
    .q_b ( ram_rd_q_b ),
    .wren_b ( ram_wr_b ), // 写端口B
    .data_b ( 32'd0 ) // 初始化过程中，写入RAM的数据为0
);

//采集摄像头场同步信号上升/下降沿
wire vsync_negedge;
wire vsync_posedge;


always @(posedge cam_clk or negedge rst_n) begin
    if (!rst_n)
        vsync_delay <= 1'b0;
    else
        vsync_delay <= cam_vsync;
end

assign vsync_negedge = vsync_delay & (!cam_vsync);
assign vsync_posedge = (!vsync_delay) & cam_vsync;

//场同步“上升沿”表示前一帧直方图统计结束，此时将RAM中的数据读出，寄存到VGA显存RAM中
always @(posedge vga_clk or negedge rst_n) begin
    if (!rst_n)
        ram_rd_b <= 1'b0;
    else begin
        if (vsync_posedge) // 上升沿拉高端口b的读使能，并维持256个时钟周期
            ram_rd_b <= 1'b1;
        else if (ram_addr_b == 8'd255)
            ram_rd_b <= 1'b0;
    end
end

//场同步“下降沿”表示新的一帧开始，此时将RAM初始化为0
//RAM的异步复位端口只能将输出端置0，初始化需要通过写操作进行
always @(posedge vga_clk or negedge rst_n) begin
    if (!rst_n)
        ram_wr_b <= 1'b0;
    else begin
        if (vsync_negedge)
            ram_wr_b <= 1'b1; // 下降沿拉高端口b的写使能，并维持256个时钟周期
        else if (ram_addr_b == 8'd255)
            ram_wr_b <= 1'b0;
    end
end

//对RAM的端口B进行读写操作时，都要遍历整个RAM的地址空间
always @(posedge vga_clk or negedge rst_n) begin
    if (!rst_n)
        ram_addr_b <= 8'd0;
    else begin
        if (ram_rd_b) // 遍历读操作地址
            ram_addr_b <= ram_addr_b + 1'b1;
        else if (ram_wr_b) // 遍历写操作地址
            ram_addr_b <= ram_addr_b + 1'b1;
        else
            ram_addr_b <= 8'd0;
    end
end

//从前一个RAM中读出直方图统计信息，延迟一个时钟周期拉高VGA显存RAM的写使能
always @(posedge vga_clk or negedge rst_n) begin
    if (!rst_n)
        ram_vga_wr <= 1'b0;
    else
        ram_vga_wr <= ram_rd_b;
end

//将直方图统计信息寄存到VGA显存RAM
always @(posedge vga_clk or negedge rst_n) begin
    if (!rst_n)
        ram_vga_wraddr <= 8'd0;
    else
        ram_vga_wraddr <= ram_addr_b;
end

//VGA显存RAM，用于在每一帧图像的直方图信息统计完毕后，寄存统计结果，该结果会用于在屏幕上显示直方图
ram_2port_vga ram_2port_vga_inst (
    .clock (vga_clk),
    .aclr (!rst_n),
    .wren (ram_vga_wr),
    .wraddress (ram_vga_wraddr),
    .data (ram_rd_q_b), // 写入的数据是从前一个RAM端口B读出的数据
    .rden (vga_rd_en),
    .rdaddress (vga_rd_addr),
    .q (vga_rd_data) // VGA刷新屏幕时，从VGA显存RAM中读取各灰度级的直方图信息
);

endmodule