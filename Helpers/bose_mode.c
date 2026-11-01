/* Narrow live experiment helper: metadata queries + existing audio/normal mode.
 * No DFU requests, firmware data, PS writes, arbitrary reports, or driver detach.
 * Accepts one Bose USB HID device (normal 40fe or audio 40fa), shared open only.
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
static int query(IOHIDDeviceRef d,const char *cmd,char *out,size_t cap) {
 uint8_t req[4]={2,(uint8_t)cmd[0],(uint8_t)cmd[1],0};
 IOReturn r=IOHIDDeviceSetReport(d,kIOHIDReportTypeFeature,2,req,sizeof(req));
 printf("{\"operation\":\"metadata_set_report\",\"command\":");quoted(cmd);printf(",\"ior\":\"0x%08x\"}\n",r);fflush(stdout);
 if(r!=kIOReturnSuccess)return 1;
 uint8_t reply[127]={2}; CFIndex len=sizeof(reply);
 r=IOHIDDeviceGetReport(d,kIOHIDReportTypeFeature,2,reply,&len);
 printf("{\"operation\":\"metadata_get_report\",\"command\":");quoted(cmd);printf(",\"ior\":\"0x%08x\",\"length\":%ld,\"response\":",r,(long)len);
 out[0]=0;
 if(r==kIOReturnSuccess&&len>=1&&reply[0]==2){size_t n=(size_t)len-1;if(n>=cap)n=cap-1;memcpy(out,reply+1,n);out[n]=0;}
 quoted(out);puts("}");fflush(stdout);
 return r!=kIOReturnSuccess || !out[0];
}
int main(int argc,char **argv) {
 if(argc!=2 || (strcmp(argv[1],"version")&&strcmp(argv[1],"audio")&&strcmp(argv[1],"normal"))){fprintf(stderr,"usage: bose_mode version|audio|normal\n");return 2;}
 int wanted=strcmp(argv[1],"normal")==0?0x40fa:0x40fe;
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
 char model[128],version[128];
 if(query(device,"pl",model,sizeof(model))||query(device,"vr",version,sizeof(version))){result=6;goto close;}
 if(!strcmp(argv[1],"version"))goto close;
 /* Guard both mode requests, including return from PID 40fa. The Phelps
  * metadata query was read-verified through Feature 2 on each USB PID. */
 if(strcmp(model,"minnow")||strcmp(version,"Main 1.0.20.")){
  fprintf(stderr,"Refusing mode change: model/version differ from analyzed Phelps 1.0.20\n");result=7;goto close;
 }
 {
  uint8_t command[3]={1,0xde,0x30};
  if(!strcmp(argv[1],"normal")){command[1]=0xff;command[2]=0xff;}
  status=IOHIDDeviceSetReport(device,kIOHIDReportTypeFeature,1,command,3);
  printf("{\"operation\":\"mode_request\",\"mode\":");quoted(argv[1]);printf(",\"report_hex\":\"%02x %02x %02x\",\"ior\":\"0x%08x\",\"firmware_write\":false}\n",command[0],command[1],command[2],status);fflush(stdout);
  if(status)result=8;
 }
close: IOHIDDeviceClose(device,kIOHIDOptionsTypeNone);
done: free(list);CFRelease(set);CFRelease(manager);return result;
}
