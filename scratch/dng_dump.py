# -*- coding: utf-8 -*-
# 解析 DNG(TIFF) 文件的 IFD 结构与全部标签值（用于字段含义分析）
import struct, sys

PATH = r'G:\DebugToolSet\IspFlow\BayerRGGB\IMG_20260817_213218.dng'

TYPE_SIZE = {1:1,2:1,3:2,4:4,5:8,6:1,7:1,8:2,9:4,10:8,11:4,12:8,13:4}
TYPE_NAME = {1:'BYTE',2:'ASCII',3:'SHORT',4:'LONG',5:'RATIONAL',6:'SBYTE',
             7:'UNDEFINED',8:'SSHORT',9:'SLONG',10:'SRATIONAL',11:'FLOAT',12:'DOUBLE',13:'IFD'}

TAGS = {
 254:'NewSubfileType',256:'ImageWidth',257:'ImageLength',258:'BitsPerSample',
 259:'Compression',262:'PhotometricInterpretation',270:'ImageDescription',
 271:'Make',272:'Model',273:'StripOffsets',274:'Orientation',277:'SamplesPerPixel',
 278:'RowsPerStrip',279:'StripByteCounts',282:'XResolution',283:'YResolution',
 284:'PlanarConfiguration',296:'ResolutionUnit',305:'Software',306:'DateTime',
 315:'Artist',322:'TileWidth',323:'TileLength',324:'TileOffsets',325:'TileByteCounts',
 330:'SubIFDs',334:'RatingPercent',700:'XMP',33421:'CFARepeatPatternDim',
 33422:'CFAPattern',33432:'Copyright',33723:'IPTC/NAA',34665:'ExifIFD',
 34853:'GPSInfoIFD',40965:'InteroperabilityIFD',
 50706:'DNGVersion',50707:'DNGBackwardVersion',50708:'UniqueCameraModel',
 50709:'LocalizedCameraModel',50710:'CFAPlaneColor',50711:'CFALayout',
 50712:'LinearizationTable',50713:'BlackLevelRepeatDim',50714:'BlackLevel',
 50715:'BlackLevelDeltaH',50716:'BlackLevelDeltaV',50717:'WhiteLevel',
 50718:'DefaultScale',50719:'DefaultCropOrigin',50720:'DefaultCropSize',
 50721:'ColorMatrix1',50722:'ColorMatrix2',50723:'CameraCalibration1',
 50724:'CameraCalibration2',50725:'ReductionMatrix1',50726:'ReductionMatrix2',
 50727:'AnalogBalance',50728:'AsShotNeutral',50729:'AsShotWhiteXY',
 50730:'BaselineExposure',50731:'BaselineNoise',50732:'BaselineSharpness',
 50733:'BayerGreenSplit',50734:'LinearResponseLimit',50735:'CameraSerialNumber',
 50736:'LensInfo',50737:'ChromaBlurRadius',50738:'AntiAliasStrength',
 50739:'ShadowScale',50740:'DNGPrivateData',50741:'MakerNoteSafety',
 50778:'CalibrationIlluminant1',50779:'CalibrationIlluminant2',
 50780:'BestQualityScale',50781:'RawDataUniqueID',50827:'OriginalRawFileName',
 50828:'OriginalRawFileData',50829:'ActiveArea',50830:'MaskedAreas',
 50831:'AsShotICCProfile',50832:'AsShotPreProfileMatrix',
 50833:'CurrentICCProfile',50834:'CurrentPreProfileMatrix',
 50879:'ColorimetricReference',50931:'CameraCalibrationSignature',
 50932:'ProfileCalibrationSignature',50933:'ExtraCameraProfiles',
 50934:'AsShotProfileName',50935:'NoiseReductionApplied',
 50936:'ProfileName',50937:'ProfileHueSatMapDims',50938:'ProfileHueSatMapData1',
 50939:'ProfileHueSatMapData2',50940:'ProfileToneCurve',50941:'ProfileEmbedPolicy',
 50942:'ProfileCopyright',50964:'ForwardMatrix1',50965:'ForwardMatrix2',
 50966:'PreviewApplicationName',50967:'PreviewApplicationVersion',
 50968:'PreviewSettingsName',50969:'PreviewSettingsDigest',
 50970:'PreviewColorSpace',50971:'PreviewDateTime',50972:'RawImageDigest',
 50973:'OriginalRawFileDigest',50974:'SubTileBlockSize',50975:'RowInterleaveFactor',
 50981:'ProfileLookTableDims',50982:'ProfileLookTableData',
 51008:'OpcodeList1',51009:'OpcodeList2',51022:'OpcodeList3',
 51041:'NoiseProfile',51043:'TimeCodes',51044:'FrameRate',51058:'TStop',
 51081:'ReelName',51105:'CameraLabel',51107:'OriginalBestQualityFinalSize',
 51108:'OriginalBestQualityFinalCrop',51109:'OriginalBestQualityFinalSharpness',
 51110:'OriginalBestQualityFinalPreview',51111:'OriginalBestQualityFinalPixelFormat',
 51125:'DefaultUserCrop',51177:'NoiseReductionApplied2',
 52525:'EnhancementParams',52632:'BaselineSharpness2',
 # EXIF IFD
 33434:'ExposureTime',33437:'FNumber',34850:'ExposureProgram',
 34855:'ISOSpeedRatings',34852:'SpectralSensitivity',
 36864:'ExifVersion',36867:'DateTimeOriginal',36868:'DateTimeDigitized',
 37121:'ComponentsConfiguration',37122:'CompressedBitsPerPixel',
 37377:'ShutterSpeedValue',37378:'ApertureValue',37379:'BrightnessValue',
 37380:'ExposureBiasValue',37381:'MaxApertureValue',37382:'SubjectDistance',
 37383:'MeteringMode',37384:'LightSource',37385:'Flash',37386:'FocalLength',
 37396:'SubjectArea',37500:'MakerNote',37510:'UserComment',
 40960:'FlashpixVersion',40961:'ColorSpace',40962:'PixelXDimension',
 40963:'PixelYDimension',41486:'FocalPlaneXResolution',41487:'FocalPlaneYResolution',
 41488:'FocalPlaneResolutionUnit',41495:'SensingMethod',41728:'FileSource',
 41729:'SceneType',41985:'CustomRendered',41986:'ExposureMode',
 41987:'WhiteBalance',41988:'DigitalZoomRatio',41989:'FocalLengthIn35mmFilm',
 41990:'SceneCaptureType',41991:'GainControl',41992:'Contrast',
 41993:'Saturation',41994:'Sharpness',42032:'CameraOwnerName',
 42033:'LensMake',42034:'LensSpecification',42035:'LensModel',42036:'LensSerialNumber',
 42080:'CompositeImage',
 # GPS
 0:'GPSVersionID',1:'GPSLatitudeRef',2:'GPSLatitude',3:'GPSLongitudeRef',
 4:'GPSLongitude',5:'GPSAltitudeRef',6:'GPSAltitude',7:'GPSTimeStamp',
 16:'GPSImgDirectionRef',17:'GPSImgDirection',29:'GPSDateStamp',
}

ILLUMINANTS = {0:'Unknown',1:'Daylight',4:'Flash',9:'Fine weather',10:'Cloudy',
 11:'Shade',12:'Daylight fluorescent',15:'White fluorescent',17:'Standard A',
 18:'Standard B',19:'Standard C',20:'D55',21:'D65',22:'D75',23:'D50',24:'ISO studio tungsten',255:'Other'}

data = open(PATH,'rb').read()
bo = data[0:2]
end = '<' if bo == b'II' else '>'
magic, ifd0_off = struct.unpack(end+'HI', data[2:8])
print(f'文件大小: {len(data)} 字节 ({len(data)/1024/1024:.2f} MB)')
print(f'字节序: {"II(小端)" if end=="<" else "MM(大端)"}, TIFF魔数: {magic}, IFD0偏移: {ifd0_off}')
print()

def read_vals(typ, cnt, valoff):
    size = TYPE_SIZE.get(typ,1)*cnt
    raw = data[valoff:valoff+size] if size>4 else struct.pack(end+'I',valoff)[:size]
    out=[]
    for i in range(cnt):
        o=i*TYPE_SIZE.get(typ,1)
        if typ in (1,6,7): out.append(raw[o])
        elif typ==2: pass
        elif typ==3: out.append(struct.unpack(end+'H',raw[o:o+2])[0])
        elif typ in (4,13): out.append(struct.unpack(end+'I',raw[o:o+4])[0])
        elif typ==8: out.append(struct.unpack(end+'h',raw[o:o+2])[0])
        elif typ==9: out.append(struct.unpack(end+'i',raw[o:o+4])[0])
        elif typ==5:
            n,d=struct.unpack(end+'II',raw[o:o+8]); out.append(n/d if d else float('nan'))
        elif typ==10:
            n,d=struct.unpack(end+'ii',raw[o:o+8]); out.append(n/d if d else float('nan'))
        elif typ==11: out.append(struct.unpack(end+'f',raw[o:o+4])[0])
        elif typ==12: out.append(struct.unpack(end+'d',raw[o:o+8])[0])
    if typ==2:
        s = raw.split(b'\x00')[0]
        try: return s.decode('utf-8',errors='replace')
        except: return repr(s)
    return out

def fmt_val(tag, typ, cnt, v):
    if isinstance(v,str): return repr(v)
    if not isinstance(v,list): return str(v)
    if tag in (273,279,324,325):  # 数据指针类：不展开
        return f'[{v[0]} ... 共{cnt}项]' if cnt>4 else str(v)
    if cnt>16: return f'[{v[0]}, {v[1]}, {v[2]}, ... 共{cnt}项]'
    if all(isinstance(x,float) for x in v):
        return '['+', '.join(f'{x:.6g}' for x in v)+']'
    return str(v)

def note(tag, typ, v):
    """附加解释性解读"""
    if tag==259: return {1:'无压缩',7:'无损JPEG',34892:'有损DNG'}.get(v[0] if isinstance(v,list) else v,'?')
    if tag==262:
        m={32803:'CFA(Bayer马赛克)',2:'RGB',34892:'线性RAW'}.get(v[0] if isinstance(v,list) else v,'?')
        return m
    if tag==33422 and isinstance(v,list):
        names={0:'R',1:'G',2:'B',3:'C',4:'M',5:'Y',6:'W'}
        return 'Bayer排列: '+''.join(names.get(x,'?') for x in v)
    if tag in (50778,50779) and isinstance(v,list):
        return ILLUMINANTS.get(v[0],'?')
    if tag==274: return {1:'正常',6:'旋转90 CW',3:'180',8:'270'}.get(v[0] if isinstance(v,list) else v,'?')
    return ''

def parse_ifd(off, name, depth=0):
    pad='  '*depth
    n = struct.unpack(end+'H', data[off:off+2])[0]
    print(f'{pad}== {name} @ {off}，共 {n} 个条目 ==')
    subifd_offs=[]; exif_off=None; gps_off=None
    for i in range(n):
        e = off+2+i*12
        tag,typ,cnt,valoff = struct.unpack(end+'HHII', data[e:e+12])
        tname = TAGS.get(tag, f'Tag{tag}')
        v = read_vals(typ,cnt,valoff)
        extra = note(tag,typ,v)
        line = f'{pad}  [{tag:5d}] {tname} ({TYPE_NAME.get(typ,typ)}x{cnt}) = {fmt_val(tag,typ,cnt,v)}'
        if extra: line += f'    <<{extra}>>'
        print(line)
        if tag==330: subifd_offs = v if isinstance(v,list) else [v]
        if tag==34665: exif_off = v if isinstance(v,int) else v[0]
        if tag==34853: gps_off = v if isinstance(v,int) else v[0]
        if tag==51009 and isinstance(v,list):
            # OpcodeList2: UNDEFINED 数组，第一个 LONG 是 opcode 数量
            size=TYPE_SIZE.get(typ,1)*cnt
            raw = data[valoff:valoff+size] if size>4 else struct.pack(end+'I',valoff)[:size]
            try:
                nop = struct.unpack(end+'I', raw[:4])[0]
                ids=[]
                p=4
                for k in range(nop):
                    oid, ver, flags, nbytes = struct.unpack(end+'IIII', raw[p:p+16])
                    ids.append(oid); p+=16+nbytes
                opnames={1:'WarpRectilinear(畸变校正)',2:'WarpFisheye',3:'WarpPerspective',
                         4:'PatchBounds',5:'PatchGain',6:'AreaMap',7:'DeltaPerRow',8:'DeltaPerColumn',
                         9:'ScalePerRow',10:'ScalePerColumn',11:'GainMap(LSC增益表)',
                         12:'FixVignetteRadial(径向暗角)'}
                print(f'{pad}      内含 {nop} 个操作码: '+', '.join(f'{i}:{opnames.get(i,"?")}' for i in ids))
            except Exception as ex:
                print(f'{pad}      (OpcodeList2 解析失败: {ex})')
    nxt = struct.unpack(end+'I', data[off+2+n*12:off+2+n*12+4])[0]
    if nxt: print(f'{pad}  下一个IFD偏移: {nxt}')
    for j,s in enumerate(subifd_offs):
        parse_ifd(s, f'SubIFD[{j}] (RAW数据)', depth+1)
    if exif_off: parse_ifd(exif_off, 'EXIF IFD', depth+1)
    if gps_off: parse_ifd(gps_off, 'GPS IFD', depth+1)
    return nxt

parse_ifd(ifd0_off, 'IFD0 (主图/预览)')
