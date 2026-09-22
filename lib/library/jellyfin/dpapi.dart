// ignore_for_file: non_constant_identifier_names, camel_case_types

import 'dart:convert';
import 'dart:ffi' as ffi;
import 'dart:typed_data';

import 'package:coriander_player/utils.dart';
import 'package:ffi/ffi.dart' as ffi;

/// Windows DPAPI 的 DATA_BLOB 结构体
final class _DataBlob extends ffi.Struct {
  @ffi.Uint32()
  external int cbData;

  external ffi.Pointer<ffi.Uint8> pbData;
}

typedef _CryptProtectDataNative = ffi.Int32 Function(
  ffi.Pointer<_DataBlob> pDataIn,
  ffi.Pointer<ffi.Utf16> szDataDescr,
  ffi.Pointer<_DataBlob> pOptionalEntropy,
  ffi.Pointer<ffi.Void> pvReserved,
  ffi.Pointer<ffi.Void> pPromptStruct,
  ffi.Uint32 dwFlags,
  ffi.Pointer<_DataBlob> pDataOut,
);
typedef _CryptProtectDataDart = int Function(
  ffi.Pointer<_DataBlob> pDataIn,
  ffi.Pointer<ffi.Utf16> szDataDescr,
  ffi.Pointer<_DataBlob> pOptionalEntropy,
  ffi.Pointer<ffi.Void> pvReserved,
  ffi.Pointer<ffi.Void> pPromptStruct,
  int dwFlags,
  ffi.Pointer<_DataBlob> pDataOut,
);

typedef _CryptUnprotectDataNative = ffi.Int32 Function(
  ffi.Pointer<_DataBlob> pDataIn,
  ffi.Pointer<ffi.Pointer<ffi.Utf16>> ppszDataDescr,
  ffi.Pointer<_DataBlob> pOptionalEntropy,
  ffi.Pointer<ffi.Void> pvReserved,
  ffi.Pointer<ffi.Void> pPromptStruct,
  ffi.Uint32 dwFlags,
  ffi.Pointer<_DataBlob> pDataOut,
);
typedef _CryptUnprotectDataDart = int Function(
  ffi.Pointer<_DataBlob> pDataIn,
  ffi.Pointer<ffi.Pointer<ffi.Utf16>> ppszDataDescr,
  ffi.Pointer<_DataBlob> pOptionalEntropy,
  ffi.Pointer<ffi.Void> pvReserved,
  ffi.Pointer<ffi.Void> pPromptStruct,
  int dwFlags,
  ffi.Pointer<_DataBlob> pDataOut,
);

typedef _LocalFreeNative = ffi.Pointer<ffi.Void> Function(
    ffi.Pointer<ffi.Void>);
typedef _LocalFreeDart = ffi.Pointer<ffi.Void> Function(
    ffi.Pointer<ffi.Void>);

/// 使用 Windows DPAPI（当前用户作用域）加密/解密敏感字符串。
///
/// 加密后的数据只能由同一 Windows 用户账户解密，适合保存 AccessToken 等凭证。
class Dpapi {
  Dpapi._();

  static final Dpapi instance = Dpapi._();

  /// 加密结果的前缀，用于区分密文与旧版明文（便于平滑迁移）
  static const String prefix = "dpapi:";

  static const int _cryptprotectUiForbidden = 0x1;

  late final ffi.DynamicLibrary _crypt32 =
      ffi.DynamicLibrary.open("crypt32.dll");
  late final ffi.DynamicLibrary _kernel32 =
      ffi.DynamicLibrary.open("kernel32.dll");

  late final _CryptProtectDataDart _cryptProtectData = _crypt32
      .lookupFunction<_CryptProtectDataNative, _CryptProtectDataDart>(
          "CryptProtectData");

  late final _CryptUnprotectDataDart _cryptUnprotectData = _crypt32
      .lookupFunction<_CryptUnprotectDataNative, _CryptUnprotectDataDart>(
          "CryptUnprotectData");

  late final _LocalFreeDart _localFree =
      _kernel32.lookupFunction<_LocalFreeNative, _LocalFreeDart>("LocalFree");

  /// 加密 [plain]，返回带 [prefix] 的 base64 密文。
  /// 加密失败时返回原文（不阻塞功能）。
  String protect(String plain) {
    final input = Uint8List.fromList(utf8.encode(plain));
    final inBlob = ffi.calloc<_DataBlob>();
    final outBlob = ffi.calloc<_DataBlob>();
    final inBuf = ffi.calloc<ffi.Uint8>(input.length);

    try {
      inBuf.asTypedList(input.length).setAll(0, input);
      inBlob.ref.cbData = input.length;
      inBlob.ref.pbData = inBuf;

      final ok = _cryptProtectData(
        inBlob,
        ffi.nullptr,
        ffi.nullptr,
        ffi.nullptr,
        ffi.nullptr,
        _cryptprotectUiForbidden,
        outBlob,
      );

      if (ok == 0) {
        LOGGER.w("[dpapi] CryptProtectData failed");
        return plain;
      }

      final encrypted = Uint8List.fromList(
        outBlob.ref.pbData.asTypedList(outBlob.ref.cbData),
      );
      _localFree(outBlob.ref.pbData.cast());
      return prefix + base64.encode(encrypted);
    } catch (err, trace) {
      LOGGER.e(err, stackTrace: trace);
      return plain;
    } finally {
      ffi.calloc.free(inBuf);
      ffi.calloc.free(inBlob);
      ffi.calloc.free(outBlob);
    }
  }

  /// 解密 [stored]。若不是本类加密的密文（没有 [prefix]），原样返回（兼容旧版明文）。
  /// 解密失败返回 null。
  String? unprotect(String stored) {
    if (!stored.startsWith(prefix)) {
      // 旧版明文，直接返回
      return stored;
    }

    final Uint8List cipher;
    try {
      cipher = base64.decode(stored.substring(prefix.length));
    } catch (_) {
      return null;
    }

    final inBlob = ffi.calloc<_DataBlob>();
    final outBlob = ffi.calloc<_DataBlob>();
    final inBuf = ffi.calloc<ffi.Uint8>(cipher.length);

    try {
      inBuf.asTypedList(cipher.length).setAll(0, cipher);
      inBlob.ref.cbData = cipher.length;
      inBlob.ref.pbData = inBuf;

      final ok = _cryptUnprotectData(
        inBlob,
        ffi.nullptr,
        ffi.nullptr,
        ffi.nullptr,
        ffi.nullptr,
        _cryptprotectUiForbidden,
        outBlob,
      );

      if (ok == 0) {
        LOGGER.w("[dpapi] CryptUnprotectData failed");
        return null;
      }

      final decrypted = Uint8List.fromList(
        outBlob.ref.pbData.asTypedList(outBlob.ref.cbData),
      );
      _localFree(outBlob.ref.pbData.cast());
      return utf8.decode(decrypted);
    } catch (err, trace) {
      LOGGER.e(err, stackTrace: trace);
      return null;
    } finally {
      ffi.calloc.free(inBuf);
      ffi.calloc.free(inBlob);
      ffi.calloc.free(outBlob);
    }
  }
}
