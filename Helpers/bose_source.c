/* Phelps 1.0.20 service authentication and narrowly scoped input selection.
 * No DFU, firmware data, PS writes, arbitrary commands, or driver detach.
 * Accepts exactly one matching Bose 40fa USB HID, shared open only.
 */
#include <CoreFoundation/CoreFoundation.h>
#include <IOKit/hid/IOHIDManager.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static int number(IOHIDDeviceRef d, CFStringRef key) {
 CFTypeRef v=IOHIDDeviceGetProperty(d,key);int n=-1;
 if(v && CFGetTypeID(v)==CFNumberGetTypeID())CFNumberGetValue(v,kCFNumberIntType,&n);
 return n;
}
static void quoted(const char *s) {
 putchar('"'); for(const unsigned char *p=(const unsigned char*)s;*p;p++){
  if(*p=='"'||*p=='\\'){putchar('\\');putchar(*p);}
  else if(*p>=32 && *p<127)putchar(*p);else printf("\\u%04x",*p);
 } putchar('"');
}

/* Explicitly authorized on the owned Phelps 1.0.20 device. No arbitrary command,
 * PS write, firmware write, factory reset, or bootloader entry. The serial and
 * computed service token stay in process memory and are never printed. */
static int metadata(IOHIDDeviceRef d,const char *cmd,char *out,size_t cap,int secret) {
 uint8_t req[127]={2}; size_t n=strlen(cmd);if(n>124)return 1;memcpy(req+1,cmd,n);
 IOReturn r=IOHIDDeviceSetReport(d,kIOHIDReportTypeFeature,2,req,(CFIndex)(n+2));
 if(r){printf("{\"operation\":\"feature2\",\"ior\":\"0x%08x\"}\n",r);return 1;}
 if(!out)return 0;
 uint8_t reply[127]={2}; CFIndex len=sizeof(reply);
 r=IOHIDDeviceGetReport(d,kIOHIDReportTypeFeature,2,reply,&len);out[0]=0;
 if(!r&&len>1&&reply[0]==2){size_t k=(size_t)len-1;if(k>=cap)k=cap-1;memcpy(out,reply+1,k);out[k]=0;}
 if(!secret){printf("{\"query\":");quoted(cmd);printf(",\"ior\":\"0x%08x\",\"response\":",r);quoted(out);puts("}");}
 return r||!out[0];
}
static char console_text[8192];static size_t console_len;
static uint8_t input_buf[512];
static void received(void *ctx,IOReturn r,void *sender,IOHIDReportType type,uint32_t rid,uint8_t *bytes,CFIndex len){
 (void)ctx;(void)sender;(void)type;if(r||rid!=5||len<=0)return;
 CFIndex start=bytes[0]==5?1:0;
 for(CFIndex i=start;i<len&&bytes[i]&&console_len<sizeof(console_text)-1;i++){
  unsigned c=bytes[i];if(c==10||c==13||(c>=32&&c<127))console_text[console_len++]=(char)c;
 }
 console_text[console_len]=0;
}
static int source(IOHIDDeviceRef d,const char *cmd,int *value){
 console_len=0;console_text[0]=0;uint8_t req[127]={6};size_t n=strlen(cmd);memcpy(req+1,cmd,n);req[n+1]='\n';
 IOReturn r=IOHIDDeviceSetReport(d,kIOHIDReportTypeFeature,6,req,(CFIndex)(n+2));
 printf("{\"operation\":\"source_command\",\"command\":");quoted(cmd);printf(",\"ior\":\"0x%08x\"}\n",r);fflush(stdout);
 if(r)return 1;CFRunLoopRunInMode(kCFRunLoopDefaultMode,0.8,false);
 char *p=strstr(console_text,"source:");int v=-1;
 if(p)sscanf(p,"source: %d",&v);
 if(!strcmp(cmd,"ss")){p=strstr(console_text,"sink state:");if(p)sscanf(p,"sink state:%d",&v);}
 printf("{\"operation\":\"console_result\",\"command\":");quoted(cmd);printf(",\"bytes\":%zu,\"value\":%d,\"error_marker\":%s}\n",console_len,v,strchr(console_text,'?')?"true":"false");
 if(value)*value=v;
 return strchr(console_text,'?')!=NULL;
}
static int service(IOHIDDeviceRef d,const char *action){
 char model[128],version[128],serial[128],auth[32];
 if(metadata(d,"pl",model,sizeof(model),0)||metadata(d,"vr",version,sizeof(version),0)||strcmp(model,"minnow")||strcmp(version,"Main 1.0.20."))return 1;
 if(metadata(d,"sn",serial,sizeof(serial),1))return 1;
 size_t n=strlen(serial);if(!n||n>17){puts("{\"error\":\"serial length outside analyzed bound\"}");return 1;}
 unsigned key=0xcb9a;
 for(size_t i=0;i<n;i+=4){unsigned word=0;size_t cnt=n-i<4?n-i:4;
  for(size_t j=0;j<cnt;j++){unsigned c=(unsigned char)serial[i+j];unsigned digit=c>='0'&&c<='9'?c-'0':c>='A'&&c<='F'?c-'A'+10:c>='a'&&c<='f'?c-'a'+10:15;word=(word<<4)|digit;}
  /* 1961a..19620 computes (16 - 4*remainder) / 2 for the variable shift. */
  word<<=(unsigned)(4-cnt)*2;key^=word;
 }
 snprintf(auth,sizeof(auth),"db 96 %04X",key&0xffff);
 IOHIDDeviceRegisterInputReportCallback(d,input_buf,sizeof(input_buf),received,NULL);
 IOHIDDeviceScheduleWithRunLoop(d,CFRunLoopGetCurrent(),kCFRunLoopDefaultMode);
 CFRunLoopRunInMode(kCFRunLoopDefaultMode,0.1,false);
 int result=metadata(d,auth,NULL,0,1);memset(serial,0,sizeof(serial));memset(auth,0,sizeof(auth));key=0;
 printf("{\"operation\":\"service_auth_request\",\"transport_success\":%s,\"token_redacted\":true}\n",result?"false":"true");
 int before=-1,after=-1,state=-1;
 if(!result)result=source(d,"ss",&state);
 if(!result)result=source(d,"so",&before);
 if(before<0||state<0)result=1; /* A real source reply proves parser access; no blind writes. */
 if(!result&&strcmp(action,"query")){
  if(!strcmp(action,"usb")&&before!=0&&before!=2&&before!=6){
   puts("{\"error\":\"unexpected prior source; refusing change\"}");result=1;
  }
  /* Feature-6 ps 1 is the existing power-on command, not a persistent-store
   * write: fb23 -> 110af -> message 672c, only while sink state is 0.
   * It never toggles an already-powered speaker or changes firmware. */
  if(!result&&state==0&&!strcmp(action,"usb")){
   result=source(d,"ps 1",NULL);
   if(!result)result=source(d,"ss",&state);
  }
  if(!result&&state==0){puts("{\"error\":\"speaker remains off\"}");result=1;}
  if(!result){
   result=source(d,!strcmp(action,"usb")?"so 6":"so 2",NULL);
   if(!result)result=source(d,"ss",&state);
   if(!result)result=source(d,"so",&after);
   /* Source 0 is normal before a PCM stream exists. State 22 selects USB;
    * source 6 identifies an active USB audio connection, not mere selection. */
   if(!strcmp(action,"usb")&&state!=22)result=1;
   if(!strcmp(action,"bluetooth")&&state!=15)result=1;
  }
 }
 IOHIDDeviceUnscheduleFromRunLoop(d,CFRunLoopGetCurrent(),kCFRunLoopDefaultMode);
 return result;
}
int main(int argc,char **argv) {
 if(argc!=2 || (strcmp(argv[1],"query")&&strcmp(argv[1],"usb")&&strcmp(argv[1],"bluetooth"))){fprintf(stderr,"usage: bose_source query|usb|bluetooth\n");return 2;}
 int wanted=0x40fa;
 IOHIDManagerRef manager=IOHIDManagerCreate(kCFAllocatorDefault,kIOHIDOptionsTypeNone);
 int vid=0x05a7;
 CFNumberRef v=CFNumberCreate(NULL,kCFNumberIntType,&vid),p=CFNumberCreate(NULL,kCFNumberIntType,&wanted);
 const void *keys[]={CFSTR(kIOHIDVendorIDKey),CFSTR(kIOHIDProductIDKey)};const void *vals[]={v,p};
 CFDictionaryRef match=CFDictionaryCreate(NULL,keys,vals,2,&kCFTypeDictionaryKeyCallBacks,&kCFTypeDictionaryValueCallBacks);
 IOHIDManagerSetDeviceMatching(manager,match);CFRelease(match);CFRelease(v);CFRelease(p);
 CFSetRef set=IOHIDManagerCopyDevices(manager);
 if(!set){fprintf(stderr,"No matching Bose HID device\n");CFRelease(manager);return 3;}
 CFIndex count=CFSetGetCount(set);IOHIDDeviceRef *list=calloc((size_t)count,sizeof(*list));CFSetGetValues(set,(const void**)list);
 IOHIDDeviceRef device=NULL;int matches=0;
 for(CFIndex i=0;i<count;i++){
  CFStringRef transport=IOHIDDeviceGetProperty(list[i],CFSTR(kIOHIDTransportKey));
  CFStringRef product=IOHIDDeviceGetProperty(list[i],CFSTR(kIOHIDProductKey));
  if(transport&&CFEqual(transport,CFSTR("USB"))&&product&&CFEqual(product,CFSTR("Bose Flex SoundLink"))&&number(list[i],CFSTR(kIOHIDPrimaryUsagePageKey))==0xff00){device=list[i];matches++;}
 }
 if(matches!=1){fprintf(stderr,"Expected one USB vendor-page HID; found %d\n",matches);free(list);CFRelease(set);CFRelease(manager);return 4;}
 printf("{\"operation\":\"target\",\"vid\":\"05a7\",\"pid\":\"%04x\",\"transport\":\"USB\",\"usage_page\":%d}\n",wanted,number(device,CFSTR(kIOHIDPrimaryUsagePageKey)));
 IOReturn status=IOHIDDeviceOpen(device,kIOHIDOptionsTypeNone);int result=0;
 if(status){fprintf(stderr,"Shared HID open failed: 0x%08x\n",status);result=5;goto done;}
 if(service(device,argv[1]))result=6;
 IOHIDDeviceClose(device,kIOHIDOptionsTypeNone);
done: free(list);CFRelease(set);CFRelease(manager);return result;
}
