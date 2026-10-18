package com.fongmi.companion;

import java.security.AlgorithmParameters;
import java.security.Key;
import java.security.Provider;
import java.security.SecureRandom;
import java.security.spec.AlgorithmParameterSpec;

import javax.crypto.BadPaddingException;
import javax.crypto.Cipher;
import javax.crypto.CipherSpi;
import javax.crypto.IllegalBlockSizeException;
import javax.crypto.NoSuchPaddingException;
import javax.crypto.ShortBufferException;

/**
 * 桌面端 JCE 补充 Provider：为 Android 专有的 "AES/CBC/PKCS7Padding" 提供别名。
 *
 * Android (Conscrypt) 支持 PKCS7Padding，而标准 JDK 只有 PKCS5Padding。
 * 对 AES（16 字节块）而言 PKCS5 与 PKCS7 填充完全等价，因此这里把
 * PKCS7 转发到 PKCS5 的实现，让加固载荷（Appgz/AppSx 等）在 JVM 上可用。
 */
public class Pkcs7Provider extends Provider {

    public Pkcs7Provider() {
        super("XiugouPkcs7", "1.0", "AES/CBC/PKCS7Padding alias to PKCS5 for desktop JVM");
        put("Cipher.AES/CBC/PKCS7Padding", Pkcs7Cipher.class.getName());
    }

    public static class Pkcs7Cipher extends CipherSpi {

        private Cipher delegate;

        private Cipher delegate() {
            if (delegate == null) {
                try {
                    delegate = Cipher.getInstance("AES/CBC/PKCS5Padding");
                } catch (Exception e) {
                    throw new IllegalStateException("PKCS5 fallback init failed", e);
                }
            }
            return delegate;
        }

        @Override
        protected void engineSetMode(String mode) {
        }

        @Override
        protected void engineSetPadding(String padding) {
        }

        @Override
        protected int engineGetBlockSize() {
            return delegate().getBlockSize();
        }

        @Override
        protected int engineGetOutputSize(int inputLen) {
            return delegate().getOutputSize(inputLen);
        }

        @Override
        protected byte[] engineGetIV() {
            return delegate().getIV();
        }

        @Override
        protected AlgorithmParameters engineGetParameters() {
            return delegate().getParameters();
        }

        @Override
        protected void engineInit(int opmode, Key key, SecureRandom random) throws java.security.InvalidKeyException {
            delegate().init(opmode, key, random);
        }

        @Override
        protected void engineInit(int opmode, Key key, AlgorithmParameterSpec params, SecureRandom random)
                throws java.security.InvalidKeyException, java.security.InvalidAlgorithmParameterException {
            delegate().init(opmode, key, params, random);
        }

        @Override
        protected void engineInit(int opmode, Key key, AlgorithmParameters params, SecureRandom random)
                throws java.security.InvalidKeyException, java.security.InvalidAlgorithmParameterException {
            delegate().init(opmode, key, params, random);
        }

        @Override
        protected byte[] engineUpdate(byte[] input, int inputOffset, int inputLen) {
            return delegate().update(input, inputOffset, inputLen);
        }

        @Override
        protected int engineUpdate(byte[] input, int inputOffset, int inputLen, byte[] output, int outputOffset)
                throws ShortBufferException {
            return delegate().update(input, inputOffset, inputLen, output, outputOffset);
        }

        @Override
        protected byte[] engineDoFinal(byte[] input, int inputOffset, int inputLen)
                throws IllegalBlockSizeException, BadPaddingException {
            return delegate().doFinal(input, inputOffset, inputLen);
        }

        @Override
        protected int engineDoFinal(byte[] input, int inputOffset, int inputLen, byte[] output, int outputOffset)
                throws ShortBufferException, IllegalBlockSizeException, BadPaddingException {
            return delegate().doFinal(input, inputOffset, inputLen, output, outputOffset);
        }
    }
}
