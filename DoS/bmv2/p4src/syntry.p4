
// for syn proxy
#define PROXY_OFF 0
#define PROXY_ON 1
// for forward strategy
#define FORWARD_DROP_PKT 0	// drop packet
#define FORWARD_REPLY_CLIENT_SA 1	// reply client with syn+ack and a certain seq no, and window size 0
#define FORWARD_CONNECT_WITH_SERVER 2	// handshake with client finished, start establishing connection with server
#define FORWARD_OPEN_WINDOW 3	// syn+ack from server received. connection established. forward this packet to client
#define FORWARD_CHANGE_SEQ_OFFSET 4 // it is a packet sent by server to client,an offset needs to be added
#define FORWARD_NORMALLY 5	// forward normally
// for tcp flags
#define TCP_FLAG_URG 0x20
#define TCP_FLAG_ACK 0x10
#define TCP_FLAG_PSH 0x08
#define TCP_FLAG_RST 0x04
#define TCP_FLAG_SYN 0x02
#define TCP_FLAG_FIN 0x01
// for clone packets
#define CLONE_NEW_CONNECTION 0
#define CLONE_UPDATE_OFFSET 1
// for meter
#define METER_COLOR_GREEN 0
#define METER_COLOR_YELLOW 1
#define METER_COLOR_RED 2

//********
//********HEADERS********
//********
header_type cpu_header_t {
	// totally self-defined header
	// for identifying packets in the control plane
	// every field should be byte-aligned
	// or it will be difficult to read in python
	fields{
		destination : 8;	// identifier. set to 0xff if it will be sent to cpu
		// is_new_connection : 8;
		seq_no_offset : 32;
	}
}

header_type ethernet_t {
	fields {
		dstAddr : 48;
		srcAddr : 48;
		etherType : 16;
	}
}

header_type ipv4_t {
	fields {
		version : 4;
		ihl : 4;
		diffserv : 8;
		totalLen : 16;
		identification : 16;
		flags : 3;
		fragOffset : 13;
		ttl : 8;
		protocol : 8;
		hdrChecksum : 16;
		srcAddr : 32;
		dstAddr: 32;
	}
} 

header_type tcp_t {
	fields {
		srcPort : 16;
		dstPort : 16;
		seqNo : 32;
		ackNo : 32;
		dataOffset : 4;
        res : 6;
		flags : 6;	 
        window : 16;
        checksum : 16;
        urgentPtr : 16;
    }
}

header cpu_header_t cpu_header;
header ethernet_t ethernet;
header ipv4_t ipv4;
header tcp_t tcp;
//********HEADERS END********



//********
//********PARSERS********
//********

// parser: start
parser start {
	set_metadata(meta.in_port, standard_metadata.ingress_port);
	return  parse_ethernet;
}

#define ETHERTYPE_IPV4 0x0800

// parser: ethernet
parser parse_ethernet {
	extract(ethernet);
	set_metadata(meta.eth_da,ethernet.dstAddr);
	set_metadata(meta.eth_sa,ethernet.srcAddr);
	return select(latest.etherType) {
		ETHERTYPE_IPV4 : parse_ipv4;
		default: ingress;
	}
}

// checksum: ipv4
field_list ipv4_checksum_list {
	ipv4.version;
	ipv4.ihl;
	ipv4.diffserv;
	ipv4.totalLen;
	ipv4.identification;
	ipv4.flags;
	ipv4.fragOffset;
	ipv4.ttl;
	ipv4.protocol;
	ipv4.srcAddr;
	ipv4.dstAddr;
}

field_list_calculation ipv4_checksum {
	input {
		ipv4_checksum_list;
	}
	algorithm : csum16;
	output_width : 16;
}

calculated_field ipv4.hdrChecksum  {
	verify ipv4_checksum;
	update ipv4_checksum;
}

#define IP_PROT_TCP 0x06

// parser: ipv4
parser parse_ipv4 {
	extract(ipv4);
	
	set_metadata(meta.ipv4_sa, ipv4.srcAddr);
	set_metadata(meta.ipv4_da, ipv4.dstAddr);
	set_metadata(meta.tcp_length, ipv4.totalLen - 20);	
	return select(ipv4.protocol) {
		IP_PROT_TCP : parse_tcp;
		default: ingress;
	}
}

// checksum: tcp
field_list tcp_checksum_list {
        ipv4.srcAddr;
        ipv4.dstAddr;
        8'0;
        ipv4.protocol;
        meta.tcp_length;
        tcp.srcPort;
        tcp.dstPort;
        tcp.seqNo;
        tcp.ackNo;
        tcp.dataOffset;
        tcp.res;
        tcp.flags; 
        tcp.window;
        tcp.urgentPtr;
        payload;
}

field_list_calculation tcp_checksum {
    input {
        tcp_checksum_list;
    }
    algorithm : csum16;
    output_width : 16;
}

calculated_field tcp.checksum {
    verify tcp_checksum if(valid(tcp));
    update tcp_checksum if(valid(tcp));
}

// parser: tcp
parser parse_tcp {
	extract(tcp);
	set_metadata(meta.tcp_sp, tcp.srcPort);
	set_metadata(meta.tcp_dp, tcp.dstPort);
	// set_metadata(meta.tcp_flags, tcp.flags);
	set_metadata(meta.tcp_seqNo, tcp.seqNo);
	set_metadata(meta.tcp_ackNo, tcp.ackNo);
	// drop as default
	set_metadata(meta.forward_strategy, FORWARD_DROP_PKT);
	return ingress;
}
//********PARSERS END********


//********
//********METADATA********
//********

header_type meta_t {
	fields {
		// ethernet information
		eth_sa:48;		// eth src addr
		eth_da:48;		// eth des addr
		// ip information
        ipv4_sa : 32;	// ipv4 src addr
        ipv4_da : 32;	// ipv4 des addr
		// tcp information
        tcp_sp : 16;	// tcp src port
        tcp_dp : 16;	// tcp des port
        tcp_length : 16;	// tcp packet length
		// tcp_flags : 6;	// tcp flags: urg, ack, psh, rst, syn, fin	
		// tcp_h1seq:32;	// 
		// tcp_seqOffset:32;
		tcp_ackNo:32;
		tcp_seqNo:32;
		// tcp_h2seq:32;
		// tcp_ackOffset:32;
		
		// forward information
		forward_strategy : 4;	// 0: drop // 1: syn+ack back to h1 // 02: syn to h2 // 03: send h2 ack // 04: resubmit // 05: forward the packet as normal  
        nhop_ipv4 : 32;	// ipv4 next hop
        // if_ipv4_addr : 32;
        // if_mac_addr : 48;
        // is_ext_if : 1;
        in_port : 8;	// in port (of switch)
		// out_port :8;		// out port (of switch)
	
		// syn meter result (3 colors)
		syn_meter_result : 2;	// METER_COLOR_RED, METER_COLOR_YELLOW, METER_COLOR_GREEN
		syn_proxy_status : 1;	// 0 for PROXY_OFF, 1 for PROXY_ON
		// 8 bits index for seq# selection in syn+ack
		eight_bit_index : 8;
		reverse_eight_bit_index : 8;
		// seq num (hash-generated) in syn+ack
		sa_seq_num : 32;

		// counter of syn packets and valid ack packets
		syn_counter_val : 32;
		valid_ack_counter_val : 32;

		// seq# offset
		seq_no_offset : 32;
		
		// tcp_session_map_index :  13;
		// dstip_pktcount_map_index: 13;
		// tcp_session_id : 16;
		
		// dstip_pktcount:32;// how many packets have been sent to this dst IP address	 
	
		// tcp_session_is_SYN: 8;// this session has sent a syn to switch
		// tcp_session_is_ACK: 8;// this session has sent a ack to switchi
		// tcp_session_h2_reply_sa:8;// h2 in this session has sent a sa to switch
	}

}
metadata meta_t meta;


field_list copy_to_cpu_fields {
	standard_metadata;
    meta;
}
//********METADATA ENDS********



//********REGISTERS********
//********11 * 8192 byte = 88KB in total********
register syn_proxy_status {
	width : 1;
	instance_count : 1;
}
register sa_seq_num_pool {
	width : 32;
	instance_count : 256;	//8 bit field
}
register syn_counter {
	// type : packets;
	// static : confirm_connection_table;
	width : 32; 
	instance_count : 1;
}
register valid_ack_counter {
	// type : packets;
	// static : valid_connection_table;
	width : 32;
	instance_count : 1;
}
//********REGISTERS ENDS********


action _no_op(){
	no_op();
}

action _drop() {
	drop();
}

// action _resubmit()
// {
// 	resubmit(resubmit_FL);
// }


//********for syn_meter_table********
// {
	meter syn_meter {
		type : packets;
		instance_count : 1;
	}
	action syn_meter_action() {
		// read syn proxy status into metadata
		execute_meter(syn_meter, 0, meta.syn_proxy_status);
	}
	table syn_meter_table {
		actions {
			syn_meter_action;
		}
	}
// }
//********for turn_on_proxy_table********
// {
	action turn_on_proxy() {
		register_write(syn_proxy_status, 0, PROXY_ON);
		// read syn proxy status into metadata
		modify_field(meta.syn_proxy_status, PROXY_ON);
	}
	table turn_on_proxy_table {
		actions {
			turn_on_proxy;
		}
	}
// }
//********for turn_off_proxy_table********
// {
	action ture_off_proxy() {
		register_write(syn_proxy_status, 0, PROXY_OFF);
		// read syn proxy status into metadata
		modify_field(meta.syn_proxy_status, PROXY_OFF);
	}
	table turn_off_proxy_table {
		actions {
			ture_off_proxy;
		}
	}
// }
//********for eight_bit_index_select_table********
// {
	action eight_bit_index_select(ip_mask, ip_e_pos, port_mask, port_e_pos) {
		// masks must be 4 bits in a row
		// e.g. 00111100 00000000 00000000 00000000 (0x3c000000)
		modify_field(meta.eight_bit_index, 
				(((ipv4.srcAddr & ip_mask) >> ip_e_pos) << 4) | ((tcp.srcPort & port_mask) >> port_e_pos));
		modify_field(meta.reverse_eight_bit_index, 
				(((ipv4.dstAddr & ip_mask) >> ip_e_pos) << 4) | ((tcp.dstPort & port_mask) >> port_e_pos));
	}
	table eight_bit_index_select_table {
		actions {
			eight_bit_index_select;
		}
	}
// }
//********for valid_connection_from_server_table********
// {
	action set_passthrough_syn_proxy_from_server(seq_no_offset) {
		modify_field(meta.forward_strategy, FORWARD_CHANGE_SEQ_OFFSET);
		modify_field(meta.seq_no_offset, seq_no_offset);
	}
	action set_passthrough_syn_proxy_from_server_for_new_connection() {
		// syn+ack packet
		modify_field(meta.forward_strategy, FORWARD_OPEN_WINDOW);	
		// set seq_no_offset
		register_read(meta.seq_no_offset, sa_seq_num_pool, meta.reverse_eight_bit_index);
		subtract_from_field(meta.seq_no_offset, tcp.seqNo);
		// update seq# offset in flow table
		clone_ingress_pkt_to_egress(CLONE_UPDATE_OFFSET, copy_to_cpu_fields);
	}
	action set_passthrough_syn_proxy_from_client() {
		modify_field(meta.forward_strategy, FORWARD_NORMALLY);
	}
	table valid_connection_table {
		reads {
			ipv4.srcAddr : exact;
			ipv4.dstAddr : exact;
			tcp.srcPort : exact;
			tcp.dstPort : exact;
			tcp.flags : exact;
		}
		actions {
			_no_op;
			set_passthrough_syn_proxy_from_client;
			set_passthrough_syn_proxy_from_server;
			set_passthrough_syn_proxy_from_server_for_new_connection;
		}
	}
// }
//********for calculate_seq_num_table********
// {
	action calculate_seq_num() {
		// select syn+ack packet seq#
		register_read(meta.sa_seq_num, sa_seq_num_pool, meta.eight_bit_index);
	}
	table calculate_seq_num_table {
		actions {
			calculate_seq_num;
		}
	}
// }
//********for reply_sa_table********
// {
	action set_reply_sa() {
		modify_field(meta.forward_strategy, FORWARD_REPLY_CLIENT_SA);
		// count: syn packet
		// count(syn_counter, 0);
		register_read(meta.syn_counter_val, syn_counter, 0);
		add_to_field(meta.syn_counter_val, 1);
		register_write(syn_counter, 0 , meta.syn_counter_val);
	}
	table reply_sa_table {
		actions {
			set_reply_sa;
		}
	}
// }
//********for confirm_connection_table********
// {
	action confirm_connection() {
		// valid ack#
		modify_field(meta.forward_strategy, FORWARD_CONNECT_WITH_SERVER);
		// count: valid ack
		// count(valid_ack_counter, 0);
		register_read(meta.valid_ack_counter_val, valid_ack_counter, 0);
		add_to_field(meta.valid_ack_counter_val, 1);
		register_write(valid_ack_counter, 0 , meta.valid_ack_counter_val);
		// insert connection in flow table
		clone_ingress_pkt_to_egress(CLONE_NEW_CONNECTION, copy_to_cpu_fields);
	}
	table confirm_connection_table {
		actions {
			confirm_connection;
		}
	}
// }
/*
//********for check_syn_and_valid_ack_num_table******
// {
	action check_syn_and_valid_ack_num() {
		// check the difference between
		// the number of syn packets and the number of valid ack
		register_read(meta.syn_counter_val, syn_counter, 0);
		register_read(meta.valid_ack_counter_val, valid_ack_counter, 0);
	}
	table check_syn_and_valid_ack_num_table {
		actions {
			check_syn_and_valid_ack_num;
		}
	}
// }
*/
//********for no_syn_proxy_table********
// {
	action no_syn_proxy_action() {
		// forward every packets normally
		modify_field(meta.forward_strategy, FORWARD_NORMALLY);	
		modify_field(meta.seq_no_offset, 0);
	}
	table no_syn_proxy_table {
		actions {
			no_syn_proxy_action;
		}
	}
// }
//********for insert_connection_table********
// {
	action insert_connection() {
		clone_ingress_pkt_to_egress(CLONE_NEW_CONNECTION, copy_to_cpu_fields);
	}
	table insert_connection_table {
		actions {
			insert_connection;
		}
	}
// }


//********for syn_proxy_forward_table********
// {
	action syn_proxy_forward_drop(){
		drop();
	}
	action syn_proxy_forward_reply_client_sa(){		
		// reply client with syn+ack and a certain seq no, and window size 0
		
		// no need to exchange ethernet values
		// since forward table will do this for us
		// // exchange src-eth, dst-eth
		// modify_field(ethernet.srcAddr, meta.eth_da);
		// modify_field(ethernet.dstAddr, meta.eth_sa);
		// exchange src-ip, dst-ip
		modify_field(ipv4.srcAddr, meta.ipv4_da);
		modify_field(ipv4.dstAddr, meta.ipv4_sa);
		// exchange src-port, dst-port
		modify_field(tcp.srcPort, meta.tcp_dp);
		modify_field(tcp.dstPort, meta.tcp_sp);
		// set tcp flags: SYN+ACK
		modify_field(tcp.flags, TCP_FLAG_ACK | TCP_FLAG_SYN);
		// set ack# to be seq# + 1
		modify_field(tcp.ackNo, tcp.seqNo + 1);
		// set seq# to be a hash val
		modify_field(tcp.seqNo, meta.sa_seq_num);
		// set window to be 0.
		// stop client from transferring data
		modify_field(tcp.window, 0);
	}
	action syn_proxy_forward_connect_with_server(){
		// handshake with client finished, start establishing connection with server
		// set seq# to be seq# - 1 (same as the beginning syn packet seq#)
		modify_field(tcp.seqNo, tcp.seqNo - 1);
		// set flag: syn
		modify_field(tcp.flags, TCP_FLAG_SYN);
		// set ack# 0 (optional)
		modify_field(tcp.ackNo, 0);
		// TODO: drop data!		
	}
	action syn_proxy_forward_open_window(){
		// syn+ack from server received. connection established. forward this packet to client
		add_to_field(tcp.seqNo, meta.seq_no_offset);
	}
	action syn_proxy_forward_change_seq_offset(){
		// it is a packet sent by server to client
		// an offset needs to be added
		add_to_field(tcp.seqNo, meta.seq_no_offset);		
	}
	action syn_proxy_forward_normally(){
		// forward normally
		// do nothing		
	}
	// it is not supposed to be a flow table
	table syn_proxy_forward_table{
		reads {
			meta.forward_strategy : exact;
		}
		actions{
			syn_proxy_forward_drop;
			syn_proxy_forward_reply_client_sa;
			syn_proxy_forward_connect_with_server;
			syn_proxy_forward_open_window;
			syn_proxy_forward_change_seq_offset;
			syn_proxy_forward_normally;
		}
	}
// }


//********for ipv4_lpm_table********
// {
	action set_nhop(nhop_ipv4, port) {
		modify_field(meta.nhop_ipv4, nhop_ipv4);
		modify_field(standard_metadata.egress_spec, port);
		add_to_field(ipv4.ttl, -1);
	}
	table ipv4_lpm_table {
		reads {
			ipv4.dstAddr : lpm;
		}
		actions {
			set_nhop;
			_drop;
		}
		size: 1024;
	}
// }


//********for forward_table********
// {
	action set_dmac(dmac) {
		modify_field(ethernet.dstAddr, dmac);
	}
	table forward_table {
		reads {
			meta.nhop_ipv4 : exact;
		}
		actions {
			set_dmac;
			_drop;
		}
		size: 512;
	}
// }

control ingress {
	// first count syn packets
	if(tcp.flags ^ TCP_FLAG_SYN == 0){
		// only has syn
		apply(syn_meter_table);
		// turn on the switch of syn proxy if syn is too much (fast)
		if(meta.syn_meter_result == METER_COLOR_RED) {
			// i guess red color means large number of syn packets
			apply(turn_on_proxy_table);
		}
	}
	// TODO: timer来改变8位selection的位置
	// select 8 bit for hashing
	// these 8 bits are used in multiple conditions
	apply(eight_bit_index_select_table);
	// check if this connection has been successfully established before
	// if so, ignore syn proxy mechanism
	apply(valid_connection_table);
	if(meta.forward_strategy == FORWARD_DROP_PKT){
		// does not exist in valid_connection_table.
		// check if syn proxy is on
		if(meta.syn_proxy_status == PROXY_ON){
			// syn proxy on
			// no need for session check since we use stateless SYN-cookie method
			if(tcp.flags & TCP_FLAG_ACK == TCP_FLAG_ACK or tcp.flags & TCP_FLAG_SYN == TCP_FLAG_SYN){
				apply(calculate_seq_num_table);
				if(tcp.flags & TCP_FLAG_ACK == 0){
					// has syn but no ack
					// send back syn+ack with special seq#
					apply(reply_sa_table);
				} else if(tcp.flags & TCP_FLAG_SYN == 0){
					// has ack but no syn
					// make sure ack# is right
					if(tcp.ackNo == meta.sa_seq_num + 1){
						apply(confirm_connection_table);
					}
				}
			}
			// check the difference between
			// the number of syn packets and the number of valid ack
			// apply(check_syn_and_valid_ack_num_table);
			
			// if the difference of the two is less than 1/8 of the smaller one
			// we think that the number of syn pkts and valid ack pkts are roughly equal
			// shutdown syn proxy
			if(meta.syn_counter_val >= meta.valid_ack_counter_val){
				if((meta.syn_counter_val - meta.valid_ack_counter_val) > (meta.valid_ack_counter_val >> 3)){
					apply(turn_off_proxy_table);
				}
			}else{
				if((meta.valid_ack_counter_val - meta.syn_counter_val) > (meta.syn_counter_val >> 3)){
					apply(turn_off_proxy_table);
				}
			}
		}else {
			// syn proxy off
			// forward every packets normally
			apply(no_syn_proxy_table);
			// store all connections while proxy is off
			// in order to avoid collision when proxy is on
			if(tcp.flags & (TCP_FLAG_ACK | TCP_FLAG_SYN) == (TCP_FLAG_ACK | TCP_FLAG_SYN)){
				// insert connection in flow table
				apply(insert_connection_table);
			}
		}
	}
	apply(syn_proxy_forward_table);	
	if(meta.forward_strategy == FORWARD_NORMALLY){
		// TODO: next steps (detect packet size & num from each source ip)

	}
	apply(ipv4_lpm_table);
    apply(forward_table);
}



//********for send_frame********
// {
	action rewrite_mac(smac) {
		modify_field(ethernet.srcAddr, smac);
	}
	table send_frame {
		reads {
			standard_metadata.egress_port: exact;
		}
		actions {
			rewrite_mac;
			_drop;
		}
		size: 256;
	}
// }

//********for send_to_cpu********
// {
	action do_cpu_encap() {
		add_header(cpu_header);
		modify_field(cpu_header.destination, 0xff);
		modify_field(cpu_header.seq_no_offset, meta.seq_no_offset);
	}

	table send_to_cpu {
		actions { do_cpu_encap; }
		size : 0;
	}
// }


control egress {
	if(standard_metadata.instance_type == 0){
		// not cloned
		apply(send_frame);
	}else{
		// cloned.
		// sent to cpu
		apply(send_to_cpu);
	}
}

