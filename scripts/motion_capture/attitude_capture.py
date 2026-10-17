#!/usr/bin/env python3
"""HeadLink local, bounded, read-only RVI attitude capture. Apache-2.0.
CRC/framing follows pinned OpenCine DumlFrame/DumlTransport. No camera commands.
Only valid 50-byte cmdset=4/cmd=5 packets are persisted; no pcap/video/addresses/UDID.
"""
import argparse, json, math, os, pathlib, re, signal, struct, subprocess, sys, threading, time

BPF='ip and udp src port 9004 and (udp[14] = 3 or udp[14] = 5)'
STAGES=[('still',10,'机身竖直固定，镜头与头部保持不动'),
 ('body_yaw',15,'头部保持不动，机身竖直，缓慢左右转约30°，各保持2秒'),
 ('body_pitch',15,'只缓慢前后倾斜机身约20°，各保持2秒，不转摇杆'),
 ('body_roll',15,'只缓慢左右侧倾机身约20°，各保持2秒，不转摇杆'),
 ('gimbal_only',15,'机身固定，仅用机身摇杆缓慢左右、上下控制约20°')]

def crc(data,initial,poly):
    value=initial
    for byte in data:
        value ^= byte
        for _ in range(8): value=(value>>1)^poly if value&1 else value>>1
    return value

def decode_datagram(data):
    if len(data)<8 or data[6] not in (3,5): return []
    declared=struct.unpack_from('<H',data)[0]&0x3fff
    if declared!=len(data) or data[7] != __import__('functools').reduce(int.__xor__,data[:7]): return []
    rows=[]; offset=8
    while offset+13 <= len(data):
        if data[offset]!=0x55: offset+=1;continue
        size=data[offset+1]|((data[offset+2]&3)<<8)
        if data[offset+2]>>2!=1 or size<13 or offset+size>len(data): offset+=1;continue
        frame=data[offset:offset+size]
        if crc(frame[:3],0x77,0x8c)!=frame[3] or crc(frame[:-2],0x3692,0x8408)!=struct.unpack_from('<H',frame,size-2)[0]: offset+=1;continue
        offset+=size
        if frame[9:11]!=b'\x04\x05' or size!=63: continue
        p=frame[11:-2]
        x,w,y,z=struct.unpack_from('<4f',p,24); norm=math.sqrt(x*x+w*w+y*y+z*z)
        candidate={'w':w,'x':x,'y':y,'z':z} if math.isfinite(norm) and abs(norm-1)<=0.001 else None
        rows.append({'dumlSequence':struct.unpack_from('<H',frame,6)[0],
          'rawAttitudeHex':p.hex(),'reportedNativePitchDeg':struct.unpack_from('<h',p,0)[0]/10,
          'reportedYawDeg':struct.unpack_from('<h',p,4)[0]/10,'reportedDisplayPitchDeg':-struct.unpack_from('<h',p,20)[0]/10,
          'modeFamilyBits':p[6]>>6,'quaternionCandidate':candidate,
          'quaternionNorm':norm if math.isfinite(norm) else None,
          'unqualifiedI16Fields':{str(k):struct.unpack_from('<h',p,k)[0] for k in (2,8,10,12,14,16,18,22,40,42,44,46,48)}})
    return rows

def datagram_from_raw_ipv4(packet):
    if len(packet)<28 or packet[0]>>4!=4 or packet[9]!=17:return None
    ihl=(packet[0]&15)*4
    if ihl<20 or len(packet)<ihl+8 or struct.unpack_from('>H',packet,6)[0]&0x3fff:return None
    src,dst,length=struct.unpack_from('>HHH',packet,ihl)
    if src!=9004 or length<8 or ihl+length>len(packet):return None
    return packet[ihl+8:ihl+length]

def read_exact(stream,count):
    data=bytearray()
    while len(data)<count:
        part=stream.read(count-len(data))
        if not part:
            if not data:return None
            raise ValueError('truncated_capture')
        data.extend(part)
    return bytes(data)

def pcap_packets(stream):
    head=read_exact(stream,24)
    if head is None:raise ValueError('no_capture_header')
    formats={b'\xd4\xc3\xb2\xa1':('<',1e6),b'\xa1\xb2\xc3\xd4':('>',1e6),b'\x4d\x3c\xb2\xa1':('<',1e9),b'\xa1\xb2\x3c\x4d':('>',1e9)}
    if head[:4] not in formats:raise ValueError('unsupported_capture_format')
    endian,scale=formats[head[:4]]
    if struct.unpack_from(endian+'I',head,20)[0] not in (12,101,228):raise ValueError('raw_ipv4_capture_required')
    while True:
        meta=read_exact(stream,16)
        if meta is None:return
        seconds,fraction,captured,original=struct.unpack(endian+'4I',meta)
        if captured>65536:raise ValueError('capture_record_too_large')
        packet=read_exact(stream,captured)
        if packet is None:raise ValueError('truncated_packet')
        yield seconds+fraction/scale,packet

def discover_udid():
    result=subprocess.run(['/usr/sbin/system_profiler','SPUSBDataType','-json','-detailLevel','mini'],capture_output=True,text=True,timeout=20,check=True)
    candidates=[]
    def walk(value):
        if isinstance(value,dict):
            if 'iphone' in str(value.get('_name','')).lower() and value.get('serial_num'):candidates.append(value['serial_num'])
            for child in value.values():walk(child)
        elif isinstance(value,list):
            for child in value:walk(child)
    walk(json.loads(result.stdout))
    if len(candidates)!=1:raise RuntimeError('请USB连接并解锁一台iPhone；若自动识别失败，可在Finder点击设备编号切到UDID后用 --udid 参数。不要把UDID发到聊天。')
    value=candidates[0]
    if re.fullmatch('[0-9A-Fa-f]{24}',value):value=value[:8]+'-'+value[8:]
    return value

def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--udid');parser.add_argument('--output',type=pathlib.Path,default=pathlib.Path(__file__).with_name('HeadLink-moving-attitude.json'))
    args=parser.parse_args()
    print('使用现有HeadLink 1.2.0，不安装App。先正常连接相机并暂停跟随；相机选Follow。')
    print('只收集姿态数据，不发送相机命令。70秒，最多6000条；不保存视频、pcap、地址或设备编号。')
    input('iPhone USB连接Mac并保持解锁，准备好后按Enter（Ctrl+C取消）：')
    udid=args.udid or discover_udid()
    if not re.fullmatch(r'[0-9a-fA-F-]{20,64}',udid):raise RuntimeError('UDID格式不可识别')
    subprocess.run(['sudo','-v'],check=True)
    result=subprocess.run(['sudo','-n','/Library/Apple/usr/bin/rvictl','-s',udid],capture_output=True,text=True,timeout=15)
    interface=re.search(r'\brvi\d+\b',result.stdout+result.stderr)
    if result.returncode or not interface:raise RuntimeError('无法建立RVI接口；设备编号与系统输出未记录，不会继续抓包。')
    name=interface.group();created='SUCCEEDED' in result.stdout
    stop=threading.Event();rows=[];errors=[];state={'stage':'preparing'};proc=None;thread=None
    try:
        proc=subprocess.Popen(['sudo','-n','/usr/sbin/tcpdump','-i',name,'-y','RAW','-U','-n','-s','512','-w','-',BPF],stdout=subprocess.PIPE,stderr=subprocess.DEVNULL)
        def consume():
            try:
                for at,packet in pcap_packets(proc.stdout):
                    datagram=datagram_from_raw_ipv4(packet)
                    if datagram:
                        for row in decode_datagram(datagram):
                            row.update(packetCaptureUnix=at,stageInstruction=state['stage'])
                            rows.append(row)
                            if len(rows)>=6000:stop.set();return
            except Exception as error:
                errors.append(type(error).__name__+':'+str(error));stop.set()
        thread=threading.Thread(target=consume,daemon=True);thread.start()
        for stage,duration,instruction in STAGES:
            if stop.is_set():break
            state['stage']=stage;print(f'{duration}秒：{instruction}',flush=True)
            if stop.wait(duration):break
    finally:
        if proc and proc.poll() is None:
            subprocess.run(['sudo','-n','kill','-INT',str(proc.pid)],stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL)
            try:proc.wait(timeout=5)
            except subprocess.TimeoutExpired:
                subprocess.run(['sudo','-n','kill','-TERM',str(proc.pid)],stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL)
        if thread:thread.join(timeout=2)
        if created:
            try:subprocess.run(['sudo','-n','/Library/Apple/usr/bin/rvictl','-x',udid],stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL,timeout=15)
            except subprocess.TimeoutExpired:errors.append('rvi_cleanup_timeout_identifier_omitted')
        output={'schema':1,'purpose':'qualify_pose_semantics_before_mobile_control','captureSucceeded':bool(rows) and not errors,
          'timeBasis':'packet_capture_time_NOT_sensor_measurement_time; no bounded_one_way_delay',
          'groundTruth':'stage labels are instructions, not independent angular measurements',
          'quaternionSemantics':'upstream world_to_camera gravity fit; heading/rolled_handle not qualified on this device',
          'noCameraCommandsSent':True,'appBuild':None,'firmware':None,
          'unavailableMetadataReason':'passive_capture_does_not_read_app_build_or_firmware',
          'sampleCount':len(rows),'validQuaternionSamples':sum(r['quaternionCandidate'] is not None for r in rows),'errors':errors,'rows':rows}
        args.output.write_text(json.dumps(output,ensure_ascii=False,indent=2,allow_nan=False)+'\n')
        print('已保存 '+str(args.output)+'；有效姿态条数 '+str(len(rows)))
        if not rows or errors:print('采集未成功，不要为此重新校准或重新安装App。',file=sys.stderr)
    return 0 if rows and not errors else 1
if __name__=='__main__':
    try:sys.exit(main())
    except KeyboardInterrupt:sys.exit(130)
    except subprocess.TimeoutExpired:print('本机USB命令超时，设备编号已省略；不需要重新校准或安装App。',file=sys.stderr);sys.exit(1)
    except subprocess.CalledProcessError:print('本机采集命令未成功；命令参数和设备编号已省略。',file=sys.stderr);sys.exit(1)
    except Exception as error:print(str(error),file=sys.stderr);sys.exit(1)
