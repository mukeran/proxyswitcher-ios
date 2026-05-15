#ifndef PROXYSWITCHER_TUN2HTTP_H
#define PROXYSWITCHER_TUN2HTTP_H

#ifdef __cplusplus
extern "C" {
#endif

int ps_t2h_android_init(void* jni_env, void* java_instance);
int ps_t2h_android_start(void* jni_env, void* java_instance, int tun_fd, int fwd53, int rcode, const char* proxy_ip, int proxy_port);
int ps_t2h_android_stop(void* jni_env, void* java_instance, int tun_fd);
int ps_t2h_android_get_mtu(void* jni_env, void* java_instance);
int ps_t2h_android_done(void* jni_env, void* java_instance);

#ifdef __cplusplus
}
#endif

#endif
