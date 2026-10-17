import io, json, math, struct, unittest
import attitude_capture as c

# Public upstream WorldLevel fixture; no personal device capture.
PAYLOAD=bytes.fromhex('F606000006008600FAFF00020E6DBE041EBA0000EAFF0400EA71193910F57F3F41C41B3C7F917FBC00000000010000000000')
def duml(p=PAYLOAD,cmdset=4,cmd=5):
    size=len(p)+13; h=bytes([0x55,size&255,4|((size>>8)&3)])
    raw=h+bytes([c.crc(h,0x77,0x8c)])+b'\x04\x02\x01\x00\x00'+bytes([cmdset,cmd])+p
    return raw+struct.pack('<H',c.crc(raw,0x3692,0x8408))
def datagram(frame=None,kind=3):
    frame=duml() if frame is None else frame
    h=struct.pack('<HHHB',0x8000|(len(frame)+8),1,8,kind)
    return h+bytes([__import__('functools').reduce(int.__xor__,h)])+frame

def ipv4(data=None,src=9004,dst=45678):
    data=datagram() if data is None else data
    udp=struct.pack('>HHHH',src,dst,len(data)+8,0)+data
    ip=bytearray(20);ip[0]=0x45;ip[9]=17;struct.pack_into('>H',ip,2,len(udp)+20)
    return bytes(ip)+udp

def pcap(packet=None,endian='<',link=101):
    packet=ipv4() if packet is None else packet
    return struct.pack(endian+'IHHIIII',0xa1b2c3d4,2,4,0,0,512,link)+struct.pack(endian+'4I',10,500000,len(packet),len(packet))+packet

class CaptureTests(unittest.TestCase):
    def test_public_attitude_fixture_and_truthful_labels(self):
        row=c.decode_datagram(datagram())[0]
        self.assertEqual(row['rawAttitudeHex'],PAYLOAD.hex())
        self.assertAlmostEqual(row['reportedNativePitchDeg'],178.2)
        self.assertAlmostEqual(row['reportedYawDeg'],0.6)
        self.assertAlmostEqual(row['quaternionNorm'],1,places=6)
        self.assertNotIn('bodyAttitude',row)
        self.assertNotIn('worldTarget',row)
        self.assertIn('2',row['unqualifiedI16Fields'])
    def test_routing_header_does_not_hide_frame(self):
        frame=b'\x00'*12+duml()
        self.assertEqual(len(c.decode_datagram(datagram(frame,kind=5))),1)
    def test_video_never_persisted(self):
        self.assertEqual(c.decode_datagram(datagram(kind=2)),[])
    def test_credentials_other_commands_never_persisted(self):
        self.assertEqual(c.decode_datagram(datagram(duml(b'private-test-ssid-pass',7,14))),[])
    def test_unknown_attitude_length_not_decoded(self):
        self.assertEqual(c.decode_datagram(datagram(duml(PAYLOAD[:-1]))),[])
    def test_crc_errors_and_truncation_rejected(self):
        frame=bytearray(duml());frame[-3]^=1
        self.assertEqual(c.decode_datagram(datagram(bytes(frame))),[])
        frame=bytearray(duml());frame[3]^=1
        self.assertEqual(c.decode_datagram(datagram(bytes(frame))),[])
        self.assertEqual(c.decode_datagram(datagram()[:-1]),[])
    def test_invalid_quaternion_is_unavailable(self):
        p=bytearray(PAYLOAD);struct.pack_into('<f',p,28,float('nan'))
        row=c.decode_datagram(datagram(duml(bytes(p))))[0]
        self.assertIsNone(row['quaternionCandidate']);self.assertIsNone(row['quaternionNorm'])
        json.dumps(row,allow_nan=False)
    def test_ipv4_control_only_not_device_addresses(self):
        self.assertEqual(c.datagram_from_raw_ipv4(ipv4()),datagram())
        self.assertIsNone(c.datagram_from_raw_ipv4(ipv4(src=44444,dst=9004)))
        self.assertIsNone(c.datagram_from_raw_ipv4(ipv4()[:23]))
    def test_ip_fragments_do_not_generate_partial_poses(self):
        packet=bytearray(ipv4());struct.pack_into('>H',packet,6,0x2000)
        self.assertIsNone(c.datagram_from_raw_ipv4(packet))
    def test_both_pcap_endian_layouts_keep_packet_timestamp_distinct(self):
        for endian in ['<','>']:
            at,packet=list(c.pcap_packets(io.BytesIO(pcap(endian=endian))))[0]
            self.assertEqual(at,10.5);self.assertEqual(packet,ipv4())
    def test_unknown_link_and_truncated_records_fail_explicitly(self):
        with self.assertRaisesRegex(ValueError,'raw_ipv4_capture_required'):list(c.pcap_packets(io.BytesIO(pcap(link=1))))
        with self.assertRaisesRegex(ValueError,'truncated'):list(c.pcap_packets(io.BytesIO(pcap()[:-1])))
    def test_filter_excludes_video_and_limits_to_camera_port(self):
        self.assertEqual(c.BPF,'ip and udp src port 9004 and (udp[14] = 3 or udp[14] = 5)')
        self.assertEqual(sum(x[1] for x in c.STAGES),70)
if __name__=='__main__':unittest.main()
