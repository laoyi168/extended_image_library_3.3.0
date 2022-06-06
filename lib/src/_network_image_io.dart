import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui show Codec;
import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:http_client_helper/http_client_helper.dart';
import 'package:path/path.dart';
import 'package:path_provider/path_provider.dart';
import 'extended_image_provider.dart';
import 'extended_network_image_provider.dart' as image_provider;
import 'platform.dart';
import 'package:xxtea/xxtea.dart';
import 'package:aes_crypt_null_safe/aes_crypt_null_safe.dart';
import 'package:worker_manager/worker_manager.dart';

class ExtendedNetworkImageProvider
    extends ImageProvider<image_provider.ExtendedNetworkImageProvider>
    with ExtendedImageProvider<image_provider.ExtendedNetworkImageProvider>
    implements image_provider.ExtendedNetworkImageProvider {
  /// Creates an object that fetches the image at the given URL.
  ///
  /// The arguments must not be null.
  ExtendedNetworkImageProvider(
    this.url, {
    this.scale = 1.0,
    this.headers,
    this.cache = false,
    this.retries = 3,
    this.timeLimit,
    this.timeRetry = const Duration(milliseconds: 100),
    this.cacheKey,
    this.printError = true,
    this.cacheRawData = false,
    this.cancelToken,
    this.imageCacheName,
    this.cacheMaxAge,
  });

  /// The name of [ImageCache], you can define custom [ImageCache] to store this provider.
  @override
  final String? imageCacheName;

  /// Whether cache raw data if you need to get raw data directly.
  /// For example, we need raw image data to edit,
  /// but [ui.Image.toByteData()] is very slow. So we cache the image
  /// data here.
  @override
  final bool cacheRawData;

  /// The time limit to request image
  @override
  final Duration? timeLimit;

  /// The time to retry to request
  @override
  final int retries;

  /// The time duration to retry to request
  @override
  final Duration timeRetry;

  /// Whether cache image to local
  @override
  final bool cache;

  /// The URL from which the image will be fetched.
  @override
  final String url;

  /// The scale to place in the [ImageInfo] object of the image.
  @override
  final double scale;

  /// The HTTP headers that will be used with [HttpClient.get] to fetch image from network.
  @override
  final Map<String, String>? headers;

  /// The token to cancel network request
  @override
  final CancellationToken? cancelToken;

  /// Custom cache key
  @override
  final String? cacheKey;

  /// print error
  @override
  final bool printError;

  /// The max duration to cahce image.
  /// After this time the cache is expired and the image is reloaded.
  @override
  final Duration? cacheMaxAge;

  @override
  ImageStreamCompleter load(
      image_provider.ExtendedNetworkImageProvider key, DecoderCallback decode) {
    // Ownership of this controller is handed off to [_loadAsync]; it is that
    // method's responsibility to close the controller's stream when the image
    // has been loaded or an error is thrown.
    final StreamController<ImageChunkEvent> chunkEvents =
        StreamController<ImageChunkEvent>();

    return MultiFrameImageStreamCompleter(
      codec: _loadAsync(
        key as ExtendedNetworkImageProvider,
        chunkEvents,
        decode,
      ),
      scale: key.scale,
      chunkEvents: chunkEvents.stream,
      informationCollector: () {
        return <DiagnosticsNode>[
          DiagnosticsProperty<ImageProvider>('Image provider', this),
          DiagnosticsProperty<image_provider.ExtendedNetworkImageProvider>(
              'Image key', key),
        ];
      },
    );
  }

  @override
  Future<ExtendedNetworkImageProvider> obtainKey(
      ImageConfiguration configuration) {
    return SynchronousFuture<ExtendedNetworkImageProvider>(this);
  }

  Future<ui.Codec> _loadAsync(
    ExtendedNetworkImageProvider key,
    StreamController<ImageChunkEvent> chunkEvents,
    DecoderCallback decode,
  ) async {
    assert(key == this);
    final String md5Key = cacheKey ?? keyToMd5(key.url);
    ui.Codec? result;
    if (cache) {
      try {
        final Uint8List? data = await _loadCache(
          key,
          chunkEvents,
          md5Key,
        );
        if (data != null) {
          result = await instantiateImageCodec(data, decode);
        }
      } catch (e) {
        if (printError) {
          print(e);
        }
      }
    }

    if (result == null) {
      try {
        final Uint8List? data = await _loadNetwork(
          key,
          chunkEvents,
        );
        if (data != null) {
          result = await instantiateImageCodec(data, decode);
        }
      } catch (e) {
        if (printError) {
          print(e);
        }
      }
    }

    //Failed to load
    if (result == null) {
      //result = await ui.instantiateImageCodec(kTransparentImage);
      return Future<ui.Codec>.error(StateError('Failed to load $url.'));
    }

    return result;
  }

  /// Get the image from cache folder.
  Future<Uint8List?> _loadCache(
    ExtendedNetworkImageProvider key,
    StreamController<ImageChunkEvent>? chunkEvents,
    String md5Key,
  ) async {
    final Directory _cacheImagesDirectory = Directory(
        join((await getTemporaryDirectory()).path, cacheImageFolderName));
    Uint8List? data;
    // exist, try to find cache image file
    if (_cacheImagesDirectory.existsSync()) {
      final File cacheFlie = File(join(_cacheImagesDirectory.path, md5Key));
      if (cacheFlie.existsSync()) {
        if (key.cacheMaxAge != null) {
          final DateTime now = DateTime.now();
          final FileStat fs = cacheFlie.statSync();
          if (now.subtract(key.cacheMaxAge!).isAfter(fs.changed)) {
            cacheFlie.deleteSync(recursive: true);
          } else {
            data = await cacheFlie.readAsBytes();
          }
        } else {
          data = await cacheFlie.readAsBytes();
        }
      }
    }
    // create folder
    else {
      await _cacheImagesDirectory.create();
    }
    // load from network
    if (data == null) {
      data = await _loadNetwork(
        key,
        chunkEvents,
      );
      if (data != null) {
        // cache image file
        await File(join(_cacheImagesDirectory.path, md5Key)).writeAsBytes(data);
      }
    }

    return data;
  }
  int hex(int c) {
    if (c >= '0'.codeUnitAt(0) && c <= '9'.codeUnitAt(0)) {
      return c - '0'.codeUnitAt(0);
    }
    if (c >= 'A'.codeUnitAt(0) && c <= 'F'.codeUnitAt(0)) {
      return (c - 'A'.codeUnitAt(0)) + 10;
    }
    return 0;
  }
  Uint8List hexToUnitList(String str) {
    int length = str.length;
    if (length % 2 != 0) {
      str = "0" + str;
      length++;
    }
    List<int> s = str.toUpperCase().codeUnits;
    Uint8List bArr = Uint8List(length >> 1);
    for (int i = 0; i < length; i += 2) {
      bArr[i >> 1] = ((hex(s[i]) << 4) | hex(s[i + 1]));
    }
    return bArr;
  }
  Future<Uint8List> decryptTest(Map<String,dynamic> params)async{
    return await decrypt(params['bytes'] as Uint8List, params['type'] as String, params['subType'] as String);
  }
  Future<Uint8List> decrypt(Uint8List bytes,String type,String subType)async{
    Uint8List res=bytes;
    switch(type){
      case 'xjmh':
        var tmp=xxtea.decrypt(bytes, 'sNtMmZ48y1KTY8wq');
        if(tmp==null){
          print('图像解密失败');
        }else{
          res=tmp;
        }
        break;
      case '91lu':
        ByteBuffer buffer = bytes.buffer;
        res=buffer.asUint8List(8);
        break;
      case 'h50':
        String hexString=utf8.decode(bytes);
        Uint8List encryptBytes=hexToUnitList(hexString);
        List<int> ivBytes=[];
        List<int> aesBytes=[];
        for (var index=0;index<encryptBytes.length;index++){
          if(index<16){
            ivBytes.add(encryptBytes[index]);
          }else{
            aesBytes.add(encryptBytes[index]);
          }
        }
        while(true){
          if(aesBytes.length%16!=0){
            aesBytes.add(0);
          }else{
            break;
          }
        }
        String base64Key='unjxhCCNd14VU1UPIDf0ryLNzx0mOmW01cdFNvCEpLI=';
        final AesCrypt crypt = AesCrypt();
        Uint8List key = base64Decode(base64Key);
        Uint8List iv = Uint8List.fromList(ivBytes);
        AesMode mode = AesMode.cfb; // Ok. I know it's meaningless here.
        crypt.aesSetKeys(key, iv);
        crypt.aesSetMode(mode);
        final Uint8List decryptedData = crypt.aesDecrypt(Uint8List.fromList(aesBytes));
        res=decryptedData;
        break;
      case 'xingba':
        final AesCrypt crypt = AesCrypt();
        Uint8List key = Uint8List.fromList(utf8.encode('525202f9149e061d'));
        AesMode mode = AesMode.ecb;
        crypt.aesSetKeys(key,crypt.createIV());
        crypt.aesSetMode(mode);
        final Uint8List decryptedData = crypt.aesDecrypt(bytes);
        res=decryptedData;
        break;
    }
    return res;
  }

  /// Get the image from network.
  Future<Uint8List?> _loadNetwork(
    ExtendedNetworkImageProvider key,
    StreamController<ImageChunkEvent>? chunkEvents,
  ) async {
    try {
      String newUrl=key.url;
      String encryptType='';
      String encryptSubType='';
      if(newUrl.endsWith('.t')||newUrl.endsWith('.tg')){
        encryptType='xjmh';
      }else if(newUrl.endsWith('.lu')){
        encryptType='91lu';
        newUrl=newUrl.replaceAll('.lu', '');
      }else if(newUrl.endsWith('.h50')){
        encryptType='h50';
        newUrl=newUrl.replaceAll('.h50', '');
      }else if(newUrl.contains('.bnc')){
        encryptType='xingba';
      }
      final Uri resolved = Uri.base.resolve(newUrl);
      final HttpClientResponse? response = await _tryGetResponse(resolved);
      if (response == null || response.statusCode != HttpStatus.ok) {
        if (response != null) {
          // The network may be only temporarily unavailable, or the file will be
          // added on the server later. Avoid having future calls to resolve
          // fail to check the network again.
          await response.drain<List<int>>(<int>[]);
        }
        return null;
      }

      Uint8List bytes = await consolidateHttpClientResponseBytes(
        response,
        onBytesReceived: chunkEvents != null
            ? (int cumulative, int? total) {
                chunkEvents.add(ImageChunkEvent(
                  cumulativeBytesLoaded: cumulative,
                  expectedTotalBytes: total,
                ));
              }
            : null,
      );
      if (bytes.lengthInBytes == 0) {
        return Future<Uint8List>.error(
            StateError('NetworkImage is an empty file: $resolved'));
      }
      if(encryptType!=''){
        /*if(encryptType=='h50'||encryptType=='xingba'){
          await Executor().warmUp(log: true,isolatesCount: 2);
          final Map<String, dynamic> data = <String, dynamic>{};
          data['bytes']=bytes;
          data['type']=encryptType;
          data['subType']=encryptSubType;
          bytes = await Executor().execute<Map<String, dynamic>,dynamic,dynamic,dynamic,Uint8List>(arg1: data, fun1: decryptTest);
        }else{
          bytes=await decrypt(bytes, encryptType,encryptSubType);
        }*/
      }

      return bytes;
    } on OperationCanceledError catch (_) {
      if (printError) {
        print('User cancel request $url.');
      }
      return Future<Uint8List>.error(StateError('User cancel request $url.'));
    } catch (e) {
      if (printError) {
        print(e);
      }
    } finally {
      await chunkEvents?.close();
    }
    return null;
  }

  Future<HttpClientResponse> _getResponse(Uri resolved) async {
    final HttpClientRequest request = await httpClient.getUrl(resolved);
    headers?.forEach((String name, String value) {
      request.headers.add(name, value);
    });
    final HttpClientResponse response = await request.close();
    if (timeLimit != null) {
      response.timeout(
        timeLimit!,
      );
    }
    return response;
  }

  // Http get with cancel, delay try again
  Future<HttpClientResponse?> _tryGetResponse(
    Uri resolved,
  ) async {
    cancelToken?.throwIfCancellationRequested();
    return await RetryHelper.tryRun<HttpClientResponse>(
      () {
        return CancellationTokenSource.register(
          cancelToken,
          _getResponse(resolved),
        );
      },
      cancelToken: cancelToken,
      timeRetry: timeRetry,
      retries: retries,
    );
  }

  @override
  bool operator ==(dynamic other) {
    if (other.runtimeType != runtimeType) {
      return false;
    }
    return other is ExtendedNetworkImageProvider &&
        url == other.url &&
        scale == other.scale &&
        cacheRawData == other.cacheRawData &&
        timeLimit == other.timeLimit &&
        cancelToken == other.cancelToken &&
        timeRetry == other.timeRetry &&
        cache == other.cache &&
        cacheKey == other.cacheKey &&
        //headers == other.headers &&
        retries == other.retries &&
        imageCacheName == other.imageCacheName &&
        cacheMaxAge == other.cacheMaxAge;
  }

  @override
  int get hashCode => hashValues(
        url,
        scale,
        cacheRawData,
        timeLimit,
        cancelToken,
        timeRetry,
        cache,
        cacheKey,
        //headers,
        retries,
        imageCacheName,
        cacheMaxAge,
      );

  @override
  String toString() => '$runtimeType("$url", scale: $scale)';

  @override

  /// Get network image data from cached
  Future<Uint8List?> getNetworkImageData({
    StreamController<ImageChunkEvent>? chunkEvents,
  }) async {
    final String uId = cacheKey ?? keyToMd5(url);

    if (cache) {
      return await _loadCache(
        this,
        chunkEvents,
        uId,
      );
    }

    return await _loadNetwork(
      this,
      chunkEvents,
    );
  }

  // Do not access this field directly; use [_httpClient] instead.
  // We set `autoUncompress` to false to ensure that we can trust the value of
  // the `Content-Length` HTTP header. We automatically uncompress the content
  // in our call to [consolidateHttpClientResponseBytes].
  static final HttpClient _sharedHttpClient = HttpClient()
    ..autoUncompress = false;

  static HttpClient get httpClient {
    HttpClient client = _sharedHttpClient;
    assert(() {
      if (debugNetworkImageHttpClientProvider != null) {
        client = debugNetworkImageHttpClientProvider!();
      }
      return true;
    }());
    return client;
  }
}
